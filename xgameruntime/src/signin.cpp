#include "runtime.h"

namespace sake {
namespace {

constexpr DWORD kPollMs = 500;
// sake looks for requests once a second.
constexpr ULONGLONG kPickUpMs = 10'000;
// A device code lives 15 minutes.
constexpr ULONGLONG kGiveUpMs = 20 * 60'000;

// One call waiting for sake. The provider and the waiting thread each hold a reference.
// Whoever claims the call finishes it, and nothing touches `async` after that:
// libHttpClient may free it inside XAsyncComplete.
struct Wait {
    std::atomic<LONG> refs{1};
    SRWLOCK lock = SRWLOCK_INIT;
    bool claimed = false;
    XAsyncBlock* async = nullptr;
    wchar_t folder[MAX_PATH] = {};
    char id[40] = {};
};

void Release(Wait* wait) noexcept
{
    if (--wait->refs == 0)
        delete wait;
}

bool Claim(Wait* wait) noexcept
{
    AcquireSRWLockExclusive(&wait->lock);
    bool mine = !wait->claimed;
    wait->claimed = true;
    ReleaseSRWLockExclusive(&wait->lock);
    return mine;
}

bool Claimed(Wait* wait) noexcept
{
    AcquireSRWLockShared(&wait->lock);
    bool claimed = wait->claimed;
    ReleaseSRWLockShared(&wait->lock);
    return claimed;
}

bool PathIn(const wchar_t* folder, const wchar_t* name, wchar_t (&path)[MAX_PATH]) noexcept
{
    return swprintf(path, MAX_PATH, L"%ls\\%ls", folder, name) >= 0;
}

// %LOCALAPPDATA%\Sake\<title ID>, made if it is not there.
bool MakeFolder(uint32_t titleId, wchar_t (&folder)[MAX_PATH]) noexcept
{
    wchar_t base[MAX_PATH];
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
    if (length == 0 || length >= MAX_PATH || swprintf(folder, MAX_PATH, L"%ls\\Sake", base) < 0)
        return false;
    CreateDirectoryW(folder, nullptr);
    if (swprintf(folder, MAX_PATH, L"%ls\\Sake\\%08X", base, titleId) < 0)
        return false;
    return CreateDirectoryW(folder, nullptr) || GetLastError() == ERROR_ALREADY_EXISTS;
}

// Calls `each(key, value)` for the lines of a file sake or this runtime wrote, once its
// first line has named the format.
template <typename Each>
bool ReadFields(const wchar_t* folder, const wchar_t* name, char* text, size_t size, Each each) noexcept
{
    wchar_t path[MAX_PATH];
    if (!PathIn(folder, name, path))
        return false;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    DWORD read = 0;
    BOOL ok = ReadFile(file, text, static_cast<DWORD>(size - 1), &read, nullptr);
    ::CloseHandle(file);
    if (!ok)
        return false;
    text[read] = '\0';

    bool first = true;
    for (char* line = text; line != nullptr && *line != '\0';) {
        char* next = strchr(line, '\n');
        if (next != nullptr)
            *next++ = '\0';
        size_t length = strlen(line);
        if (length > 0 && line[length - 1] == '\r')
            line[length - 1] = '\0';
        if (first) {
            if (strcmp(line, "sake 1") != 0)
                return false;
            first = false;
        } else if (char* space = strchr(line, ' ')) {
            *space = '\0';
            each(line, space + 1);
        }
        line = next;
    }
    return !first;
}

bool WriteRequest(const Wait& wait) noexcept
{
    wchar_t partial[MAX_PATH], request[MAX_PATH];
    if (!PathIn(wait.folder, L"request.partial", partial) || !PathIn(wait.folder, L"request", request))
        return false;
    HANDLE file = CreateFileW(partial, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    char text[64];
    int length = snprintf(text, sizeof(text), "sake 1\nrequest %s\n", wait.id);
    DWORD written = 0;
    BOOL ok = length > 0 && WriteFile(file, text, static_cast<DWORD>(length), &written, nullptr) &&
              written == static_cast<DWORD>(length);
    ::CloseHandle(file);
    // Renamed into place, so sake never reads half a request.
    return ok && MoveFileExW(partial, request, MOVEFILE_REPLACE_EXISTING);
}

// Unless the title has asked again since, which replaced the file.
void TakeRequestBack(const Wait& wait) noexcept
{
    char text[256];
    bool ours = false;
    ReadFields(wait.folder, L"request", text, sizeof(text), [&](const char* key, const char* value) {
        ours = ours || (strcmp(key, "request") == 0 && strcmp(value, wait.id) == 0);
    });
    wchar_t path[MAX_PATH];
    if (ours && PathIn(wait.folder, L"request", path))
        DeleteFileW(path);
}

void LogSession(const Wait& wait) noexcept
{
    char text[65536];
    int tokens = 0;
    bool person = false;
    ReadFields(wait.folder, L"session", text, sizeof(text), [&](const char* key, const char*) {
        tokens += strcmp(key, "token") == 0;
        person = person || strcmp(key, "xuid") == 0;
    });
    Log("sign-in %s: sake signed %s in, %d tokens in the session; the user is not handed to the title yet",
        wait.id, person ? "somebody" : "nobody it could name", tokens);
}

DWORD WINAPI WaitForSake(void* context) noexcept
{
    Wait* wait = static_cast<Wait*>(context);
    ULONGLONG started = GetTickCount64();
    bool pickedUp = false;
    char state[16] = "";
    char reason[256] = "";

    while (!Claimed(wait)) {
        Sleep(kPollMs);
        char text[1024];
        char request[40] = "", seen[16] = "", why[256] = "";
        ReadFields(wait->folder, L"answer", text, sizeof(text), [&](const char* key, const char* value) {
            if (strcmp(key, "request") == 0)
                strncpy_s(request, value, _TRUNCATE);
            else if (strcmp(key, "state") == 0)
                strncpy_s(seen, value, _TRUNCATE);
            else if (strcmp(key, "reason") == 0)
                strncpy_s(why, value, _TRUNCATE);
        });
        if (strcmp(request, wait->id) == 0) {
            if (strcmp(seen, "waiting") != 0) {
                strncpy_s(state, seen, _TRUNCATE);
                strncpy_s(reason, why, _TRUNCATE);
                break;
            }
            if (!pickedUp)
                Log("sign-in %s: sake has it after %llu ms", wait->id, GetTickCount64() - started);
            pickedUp = true;
        }

        ULONGLONG elapsed = GetTickCount64() - started;
        if (!pickedUp && elapsed >= kPickUpMs) {
            strcpy_s(state, "unanswered");
            break;
        }
        if (elapsed >= kGiveUpMs) {
            strcpy_s(state, "timed out");
            break;
        }
    }

    if (Claim(wait)) {
        if (strcmp(state, "signed-in") == 0)
            LogSession(*wait);
        else if (strcmp(state, "unanswered") == 0)
            Log("sign-in %s: nothing picked it up in %llu s; sake has to be running to answer", wait->id,
                kPickUpMs / 1000);
        else
            Log("sign-in %s: %s %s", wait->id, state, reason);
        TakeRequestBack(*wait);
        ::XAsyncComplete(wait->async, E_GAMEUSER_NO_DEFAULT_USER, 0);
    }
    Release(wait);
    return 0;
}

HRESULT CALLBACK Provider(XAsyncOp op, const XAsyncProviderData* data) noexcept
{
    Wait* wait = static_cast<Wait*>(data->context);
    switch (op) {
    case XAsyncOp::Begin: {
        wait->async = data->async;
        uint32_t titleId = TitleId();
        GUID guid;
        char text[40];
        if (titleId == 0 || !MakeFolder(titleId, wait->folder) || FAILED(CoCreateGuid(&guid))) {
            Log("sign-in: no folder to ask sake in (title ID %08X)", titleId);
            return E_GAMEUSER_NO_DEFAULT_USER;
        }
        FormatGuid(guid, text);
        snprintf(wait->id, sizeof(wait->id), "{%s}", text);
        if (!WriteRequest(*wait)) {
            Log("sign-in %s: the request could not be written to %ls", wait->id, wait->folder);
            return E_GAMEUSER_NO_DEFAULT_USER;
        }

        ++wait->refs;
        HANDLE thread = CreateThread(nullptr, 0, WaitForSake, wait, 0, nullptr);
        if (thread == nullptr) {
            --wait->refs;
            TakeRequestBack(*wait);
            return E_GAMEUSER_NO_DEFAULT_USER;
        }
        ::CloseHandle(thread);
        Log("sign-in %s: asked sake in %ls", wait->id, wait->folder);
        return S_OK;
    }
    case XAsyncOp::Cancel:
        if (Claim(wait)) {
            Log("sign-in %s: cancelled by the title", wait->id);
            TakeRequestBack(*wait);
            ::XAsyncComplete(data->async, E_ABORT, 0);
        }
        return S_OK;
    case XAsyncOp::Cleanup:
        Release(wait);
        return S_OK;
    default:
        return S_OK;
    }
}

}  // namespace

// The wait is a thread of its own and never work on the caller's queue: terminating that
// queue cancels whatever is still queued on it, so a caller that terminates it straight
// after asking, as docs/gdk.md's probe does, would see a wait scheduled there with
// XAsyncSchedule end the call with E_ABORT at once. Minecraft Dungeons II polls until the
// call completes and only then terminates. Either way the queue stays open, because
// XAsyncBegin holds off its termination until the call completes, and until then the
// completion port only marks callbacks canceled rather than refusing them. A refusal would
// be fatal: libHttpClient fails fast when it cannot post a completion.
HRESULT AskSakeToSignIn(XAsyncBlock* async, const void* identity, const char* identityName) noexcept
{
    Wait* wait = new (std::nothrow) Wait;
    if (wait == nullptr)
        return E_OUTOFMEMORY;
    HRESULT hr = ::XAsyncBegin(async, wait, identity, identityName, Provider);
    // Only a failure before the provider ever ran; after that, its Cleanup releases.
    if (FAILED(hr))
        delete wait;
    return hr;
}

}  // namespace sake
