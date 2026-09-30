#include "mailbox.h"

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
    Finish finish;
    Payload payload;
};

// There is one request file per title and a title asks for several tokens at once, so a call
// that asks while a request is out joins it: replacing the file would leave the first call
// waiting for an answer to a request sake never saw.
SRWLOCK g_askLock = SRWLOCK_INIT;
char g_askId[40];
ULONGLONG g_askSince;

void ForgetAsk(const char* id) noexcept
{
    AcquireSRWLockExclusive(&g_askLock);
    if (strcmp(g_askId, id) == 0)
        g_askId[0] = '\0';
    ReleaseSRWLockExclusive(&g_askLock);
}

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
        if (strcmp(state, "unanswered") == 0)
            Log("sign-in %s: nothing picked it up in %llu s; sake has to be running to answer", wait->id,
                kPickUpMs / 1000);
        else
            Log("sign-in %s: %s after %llu ms %s", wait->id, state, GetTickCount64() - started, reason);
        TakeRequestBack(*wait);
        ForgetAsk(wait->id);
        HRESULT hr = wait->finish(state, wait->payload);
        ::XAsyncComplete(wait->async, hr, SUCCEEDED(hr) ? wait->payload.Size() : 0);
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
        if (!MailboxFolder(wait->folder)) {
            Log("sign-in: no folder to ask sake in (title ID %08X)", TitleId());
            return E_GAMEUSER_RESOLVE_USER_ISSUE_REQUIRED;
        }
        AcquireSRWLockExclusive(&g_askLock);
        bool joined = g_askId[0] != '\0' && GetTickCount64() - g_askSince < kGiveUpMs;
        bool written = joined;
        if (joined) {
            strcpy_s(wait->id, g_askId);
        } else {
            GUID guid;
            char text[40];
            if (SUCCEEDED(CoCreateGuid(&guid))) {
                FormatGuid(guid, text);
                snprintf(wait->id, sizeof(wait->id), "{%s}", text);
                written = WriteRequest(*wait);
            }
            if (written) {
                strcpy_s(g_askId, wait->id);
                g_askSince = GetTickCount64();
            }
        }
        ReleaseSRWLockExclusive(&g_askLock);
        if (!written) {
            Log("sign-in: the request could not be written to %ls", wait->folder);
            return E_GAMEUSER_RESOLVE_USER_ISSUE_REQUIRED;
        }

        ++wait->refs;
        HANDLE thread = CreateThread(nullptr, 0, WaitForSake, wait, 0, nullptr);
        if (thread == nullptr) {
            --wait->refs;
            TakeRequestBack(*wait);
            return E_GAMEUSER_RESOLVE_USER_ISSUE_REQUIRED;
        }
        ::CloseHandle(thread);
        Log("sign-in %s: %s sake in %ls", wait->id, joined ? "joined a request to" : "asked", wait->folder);
        return S_OK;
    }
    case XAsyncOp::GetResult:
        wait->payload.Write(data->buffer);
        return S_OK;
    case XAsyncOp::Cancel:
        // The request stays out, since another call may have joined it.
        if (Claim(wait)) {
            Log("sign-in %s: cancelled by the title", wait->id);
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

struct Result {
    HRESULT result;
    Payload payload;
};

HRESULT CALLBACK CompleteNowProvider(XAsyncOp op, const XAsyncProviderData* data) noexcept
{
    Result* now = static_cast<Result*>(data->context);
    switch (op) {
    case XAsyncOp::Begin:
        if (FAILED(now->result))
            return now->result;
        ::XAsyncComplete(data->async, now->result, now->payload.Size());
        return S_OK;
    case XAsyncOp::GetResult:
        now->payload.Write(data->buffer);
        return S_OK;
    case XAsyncOp::Cleanup:
        delete now;
        return S_OK;
    default:
        return S_OK;
    }
}

}  // namespace

HRESULT CompleteNow(XAsyncBlock* async, const void* identity, const char* identityName, HRESULT result,
                    Payload payload) noexcept
{
    Result* now = new (std::nothrow) Result{result, std::move(payload)};
    if (now == nullptr)
        return E_OUTOFMEMORY;
    HRESULT hr = ::XAsyncBegin(async, now, identity, identityName, CompleteNowProvider);
    // Only a failure before the provider ever ran; after that, its Cleanup deletes.
    if (FAILED(hr))
        delete now;
    return hr;
}

// The wait is a thread of its own and never work on the caller's queue: terminating that
// queue cancels whatever is still queued on it, so a caller that terminates it straight
// after asking, as docs/gdk.md's probe does, would see a wait scheduled there with
// XAsyncSchedule end the call with E_ABORT at once. Minecraft Dungeons II polls until the
// call completes and only then terminates. Either way the queue stays open, because
// XAsyncBegin holds off its termination until the call completes, and until then the
// completion port only marks callbacks canceled rather than refusing them. A refusal would
// be fatal: libHttpClient fails fast when it cannot post a completion.
HRESULT AskSake(XAsyncBlock* async, const void* identity, const char* identityName, Finish finish) noexcept
{
    Wait* wait = new (std::nothrow) Wait;
    if (wait == nullptr)
        return E_OUTOFMEMORY;
    wait->finish = std::move(finish);
    HRESULT hr = ::XAsyncBegin(async, wait, identity, identityName, Provider);
    if (FAILED(hr))
        delete wait;
    return hr;
}

}  // namespace sake
