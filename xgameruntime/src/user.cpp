#include "runtime.h"
#include "guids.h"

namespace sake {
namespace {

constexpr uint32_t kAddDefaultUserSilently = 0x1;
constexpr uint32_t kForceRefresh = 0x1;
constexpr uint64_t kPlaceholderXuid = 1;
// A token closer to its expiry than this is fetched again rather than handed out.
constexpr uint64_t kMarginSeconds = 5 * 60;
// A ForceRefresh goes to sake only this long after an ask of it last ended. XSAPI puts the
// option on the person's next token request after any 401, whatever its URL, and a refusal
// no new token cures, such as multiplayer activity's missing title claim, comes back every
// time.
constexpr ULONGLONG kForceRefreshAfterMs = 15 * 60'000;
const char* const kIdentity = "http://xboxlive.com";

const void* const kAddIdentity = &kAddIdentity;
const void* const kAddByIdIdentity = &kAddByIdIdentity;
const void* const kTokenIdentity = &kTokenIdentity;
const void* const kTokenUtf16Identity = &kTokenUtf16Identity;

}  // namespace

// There is one user, and a handle is this object's address.
struct XUser {
};

namespace {

XUser g_user;

// Who the user is: the person the session names, or, until there is a session that lasts,
// a placeholder the way the community stand-in answers (docs/gdk.md).
struct Person {
    SRWLOCK lock = SRWLOCK_INIT;
    bool known = false;
    Session session;
    uint64_t placeholderXuid = kPlaceholderXuid;
};

Person g_person;
std::atomic<ULONGLONG> g_askEndedAt{0};

bool IsUser(XUserHandle user) noexcept
{
    return user == &g_user;
}

// A session is taken when its identity token lasts beyond the margin. Once the person is
// known they stay known; only their tokens go stale.
bool Refresh() noexcept
{
    Session read;
    bool usable = ReadSession(read);
    if (usable) {
        const Session::Token* identity = read.Named(kIdentity);
        usable = identity != nullptr && identity->notAfter > Now() + kMarginSeconds;
    }
    AcquireSRWLockExclusive(&g_person.lock);
    if (usable) {
        if (!g_person.known && g_person.placeholderXuid != kPlaceholderXuid && g_person.placeholderXuid != read.xuid)
            Log("user: the session names someone other than the XUID the title added");
        if (!g_person.known)
            Log("user: the person from the session, XUID of %zu digits", std::to_string(read.xuid).size());
        g_person.session = std::move(read);
        g_person.known = true;
    }
    bool known = g_person.known;
    ReleaseSRWLockExclusive(&g_person.lock);
    return known;
}

uint64_t Xuid() noexcept
{
    AcquireSRWLockShared(&g_person.lock);
    uint64_t xuid = g_person.known ? g_person.session.xuid : g_person.placeholderXuid;
    ReleaseSRWLockShared(&g_person.lock);
    return xuid;
}

Payload UserPayload() noexcept
{
    Payload payload;
    payload.kind = Payload::Kind::User;
    payload.user = &g_user;
    return payload;
}

enum class Lookup { Token, NotCovered, Missing };

// The Authorization value a URL takes, when the person is known and its token lasts.
Lookup LookUp(const std::string& url, std::string& authorization) noexcept
{
    Lookup result = Lookup::Missing;
    AcquireSRWLockShared(&g_person.lock);
    if (g_person.known) {
        bool covered = false;
        const Session::Token* token = g_person.session.TokenFor(url.c_str(), &covered);
        if (!covered) {
            result = Lookup::NotCovered;
        } else if (token != nullptr && token->notAfter > Now() + kMarginSeconds) {
            authorization = "XBL3.0 x=" + g_person.session.userHash + ";" + token->value;
            result = Lookup::Token;
        }
    }
    ReleaseSRWLockShared(&g_person.lock);
    return result;
}

Payload TokenPayload(Payload::Kind kind, std::string authorization) noexcept
{
    Payload payload;
    payload.kind = kind;
    payload.token = std::move(authorization);
    return payload;
}

// sake is asked here, at the first request for a token, because that is where the title
// has its own screen up (docs/gdk.md).
HRESULT RequestToken(XAsyncBlock* async, const void* identity, const char* name, std::string url, uint32_t options,
                     Payload::Kind kind) noexcept
{
    Refresh();
    bool force = (options & kForceRefresh) != 0;
    ULONGLONG ended = g_askEndedAt;
    ULONGLONG since = GetTickCount64() - ended;
    if (force && ended != 0 && since < kForceRefreshAfterMs) {
        Log("token for %s: ForceRefresh %llu s after the last ask of sake ended, not asking again", url.c_str(),
            static_cast<unsigned long long>(since / 1000));
        force = false;
    }
    std::string authorization;
    Lookup found = force ? Lookup::Missing : LookUp(url, authorization);
    if (found == Lookup::NotCovered) {
        Log("token for %s: no relying party covers it", url.c_str());
        return CompleteNow(async, identity, name, E_GAMEUSER_NO_TOKEN_REQUIRED, {});
    }
    if (found == Lookup::Token) {
        Log("token for %s: %zu bytes from the session", url.c_str(), authorization.size());
        return CompleteNow(async, identity, name, S_OK, TokenPayload(kind, std::move(authorization)));
    }
    Log("token for %s: asking sake", url.c_str());
    return AskSake(async, identity, name, [url, kind](const char* state, Payload& payload) noexcept -> HRESULT {
        g_askEndedAt = GetTickCount64();
        if (strcmp(state, "signed-in") != 0)
            return E_GAMEUSER_RESOLVE_USER_ISSUE_REQUIRED;
        Refresh();
        std::string authorization;
        switch (LookUp(url, authorization)) {
        case Lookup::Token:
            Log("token for %s: %zu bytes once sake had signed in", url.c_str(), authorization.size());
            payload = TokenPayload(kind, std::move(authorization));
            return S_OK;
        case Lookup::NotCovered:
            return E_GAMEUSER_NO_TOKEN_REQUIRED;
        default:
            Log("token for %s: sake signed in, and the session still has no token for it", url.c_str());
            return E_GAMEUSER_RESOLVE_USER_ISSUE_REQUIRED;
        }
    });
}

std::string Narrow(const wchar_t* text) noexcept
{
    std::string narrow;
    int length = text != nullptr ? WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr) : 0;
    if (length > 1) {
        narrow.resize(static_cast<size_t>(length) - 1);
        WideCharToMultiByte(CP_UTF8, 0, text, -1, narrow.data(), length, nullptr, nullptr);
    }
    return narrow;
}

HRESULT DuplicateHandle(void*, XUserHandle user, XUserHandle* duplicate) noexcept
{
    SAKE_TRACE("%p", user);
    if (duplicate == nullptr)
        return E_POINTER;
    *duplicate = IsUser(user) ? user : nullptr;
    return IsUser(user) ? S_OK : E_INVALIDARG;
}

void CloseHandle(void*, XUserHandle user) noexcept
{
    SAKE_TRACE("%p", user);
}

int32_t Compare(void*, XUserHandle a, XUserHandle b) noexcept
{
    SAKE_TRACE("%p %p", a, b);
    return a == b ? 0 : (a < b ? -1 : 1);
}

HRESULT GetMaxUsers(void*, uint32_t* maxUsers) noexcept
{
    SAKE_TRACE("");
    if (maxUsers == nullptr)
        return E_POINTER;
    *maxUsers = 1;
    return S_OK;
}

typedef void(CALLBACK* ChangeCallback)(void* context, XUserLocalId user, uint32_t event);

struct ChangeRegistration {
    XTaskQueueHandle queue;
    void* context;
    ChangeCallback callback;
    uint64_t token;
};

SRWLOCK g_changeLock = SRWLOCK_INIT;
std::vector<ChangeRegistration> g_changes;
bool g_announced;

struct Delivery {
    ChangeCallback callback;
    void* context;
};

void CALLBACK Deliver(void* context, bool canceled) noexcept
{
    Delivery* delivery = static_cast<Delivery*>(context);
    if (!canceled)
        delivery->callback(delivery->context, XUserLocalId{1}, 0);  // SignedInAgain
    delete delivery;
}

// The community stand-in delivers SignedInAgain once after the silent add, on the completion
// port of the queue the title registered, and Minecraft Dungeons II answers it. Whether the
// game would go on without it has not been tried (docs/gdk.md).
void AnnounceSignedIn() noexcept
{
    AcquireSRWLockExclusive(&g_changeLock);
    std::vector<ChangeRegistration> registrations = g_announced ? std::vector<ChangeRegistration>() : g_changes;
    g_announced = true;
    ReleaseSRWLockExclusive(&g_changeLock);
    for (const ChangeRegistration& registration : registrations) {
        Delivery* delivery = new (std::nothrow) Delivery{registration.callback, registration.context};
        if (delivery == nullptr)
            continue;
        HRESULT hr = ::XTaskQueueSubmitCallback(registration.queue, XTaskQueuePort::Completion, delivery, Deliver);
        Log("user: SignedInAgain for registration %llu -> %#lx", static_cast<unsigned long long>(registration.token),
            static_cast<unsigned long>(hr));
        if (FAILED(hr))
            delete delivery;
    }
}

// Every add succeeds at once. The sign-in waits for the first token request.
HRESULT AddAsync(void*, uint32_t options, XAsyncBlock* async) noexcept
{
    bool known = Refresh();
    SAKE_TRACE("options %#x -> %s", options, known ? "the person" : "a placeholder");
    HRESULT hr = CompleteNow(async, kAddIdentity, "XUserAddAsync", S_OK, UserPayload());
    if (SUCCEEDED(hr) && (options & kAddDefaultUserSilently))
        AnnounceSignedIn();
    return hr;
}

HRESULT AddResult(void*, XAsyncBlock* async, XUserHandle* user) noexcept
{
    if (user != nullptr)
        *user = nullptr;
    HRESULT hr = ::XAsyncGetResult(async, kAddIdentity, sizeof(XUserHandle), user, nullptr);
    SAKE_TRACE("%p -> %#lx", async, static_cast<unsigned long>(hr));
    return hr;
}

HRESULT GetLocalId(void*, XUserHandle user, XUserLocalId* id) noexcept
{
    SAKE_TRACE("%p", user);
    if (id == nullptr)
        return E_POINTER;
    if (!IsUser(user))
        return E_INVALIDARG;
    id->value = 1;
    return S_OK;
}

HRESULT FindUserByLocalId(void*, XUserLocalId id, XUserHandle* user) noexcept
{
    SAKE_TRACE("%llu", static_cast<unsigned long long>(id.value));
    if (user == nullptr)
        return E_POINTER;
    *user = id.value == 1 ? &g_user : nullptr;
    return id.value == 1 ? S_OK : E_GAMEUSER_USER_NOT_FOUND;
}

HRESULT GetId(void*, XUserHandle user, uint64_t* id) noexcept
{
    SAKE_TRACE("%p", user);
    if (id == nullptr)
        return E_POINTER;
    if (!IsUser(user))
        return E_INVALIDARG;
    *id = Xuid();
    return S_OK;
}

HRESULT FindUserById(void*, uint64_t id, XUserHandle* user) noexcept
{
    SAKE_TRACE("");
    if (user == nullptr)
        return E_POINTER;
    bool ours = id == Xuid();
    *user = ours ? &g_user : nullptr;
    return ours ? S_OK : E_GAMEUSER_USER_NOT_FOUND;
}

HRESULT GetIsGuest(void*, XUserHandle user, bool* isGuest) noexcept
{
    SAKE_TRACE("%p", user);
    if (isGuest == nullptr)
        return E_POINTER;
    *isGuest = false;
    return IsUser(user) ? S_OK : E_INVALIDARG;
}

HRESULT GetState(void*, XUserHandle user, uint32_t* state) noexcept
{
    SAKE_TRACE("%p", user);
    if (state == nullptr)
        return E_POINTER;
    *state = 0;  // SignedIn
    return IsUser(user) ? S_OK : E_INVALIDARG;
}

HRESULT Slot12(void*) noexcept
{
    SAKE_TRACE("unknown slot 12");
    return kUnknownSlot;
}

HRESULT Unsupported(const char* call, XUserHandle user) noexcept
{
    SAKE_TRACE("%s %p", call, user);
    return E_NOTIMPL;
}

HRESULT GetGamerPictureAsync(void*, XUserHandle user, uint32_t, XAsyncBlock*) noexcept
{
    return Unsupported(__func__, user);
}

HRESULT ResultSizeOfNothing(void*, XAsyncBlock* async, size_t* size) noexcept
{
    SAKE_TRACE("%p", async);
    if (size != nullptr)
        *size = 0;
    return E_INVALIDARG;
}

HRESULT GetGamerPictureResult(void*, XAsyncBlock* async, size_t, void*, size_t*) noexcept
{
    SAKE_TRACE("%p", async);
    return E_INVALIDARG;
}

HRESULT GetAgeGroup(void*, XUserHandle user, uint32_t* group) noexcept
{
    SAKE_TRACE("%p", user);
    if (group == nullptr)
        return E_POINTER;
    AcquireSRWLockShared(&g_person.lock);
    const std::string& age = g_person.known ? g_person.session.ageGroup : std::string();
    *group = age == "Adult" ? 3 : age == "Teen" ? 2 : age == "Child" ? 1 : 0;
    ReleaseSRWLockShared(&g_person.lock);
    return IsUser(user) ? S_OK : E_INVALIDARG;
}

// A placeholder has every privilege: the title asks before the person is known.
HRESULT CheckPrivilege(void*, XUserHandle user, uint32_t, uint32_t privilege, bool* has, uint32_t* reason) noexcept
{
    if (has == nullptr)
        return E_POINTER;
    AcquireSRWLockShared(&g_person.lock);
    bool granted = !g_person.known;
    if (g_person.known) {
        const char* list = g_person.session.privileges.c_str();
        for (char* end = nullptr; *list != '\0'; list = end) {
            unsigned long value = strtoul(list, &end, 10);
            if (end == list)
                break;
            granted = granted || value == privilege;
        }
    }
    ReleaseSRWLockShared(&g_person.lock);
    SAKE_TRACE("%p privilege %u -> %d", user, privilege, granted);
    *has = granted;
    if (reason != nullptr)
        *reason = granted ? 0 : 0xFFFFFFFF;
    return IsUser(user) ? S_OK : E_INVALIDARG;
}

HRESULT ResolvePrivilegeWithUiAsync(void*, XUserHandle user, uint32_t, uint32_t privilege, XAsyncBlock*) noexcept
{
    SAKE_TRACE("%p privilege %u", user, privilege);
    return E_NOTIMPL;
}

HRESULT ResultOfNothing(void*, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%p", async);
    return E_INVALIDARG;
}

HRESULT GetTokenAndSignatureAsync(void*, XUserHandle user, uint32_t options, const char* method, const char* url,
                                  size_t, const void*, size_t, const void*, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%p options %#x %s %s", user, options, method ? method : "", url ? url : "");
    if (!IsUser(user) || url == nullptr)
        return E_INVALIDARG;
    return RequestToken(async, kTokenIdentity, "XUserGetTokenAndSignatureAsync", url, options, Payload::Kind::Token);
}

HRESULT GetTokenAndSignatureResultSize(void*, XAsyncBlock* async, size_t* size) noexcept
{
    HRESULT hr = ::XAsyncGetResultSize(async, size);
    SAKE_TRACE("%p -> %#lx", async, static_cast<unsigned long>(hr));
    return hr;
}

HRESULT TokenResult(XAsyncBlock* async, const void* identity, size_t size, void* buffer, void** data,
                    size_t* used) noexcept
{
    if (data != nullptr)
        *data = nullptr;
    HRESULT hr = ::XAsyncGetResult(async, identity, size, buffer, used);
    if (SUCCEEDED(hr) && data != nullptr)
        *data = buffer;
    return hr;
}

HRESULT GetTokenAndSignatureResult(void*, XAsyncBlock* async, size_t size, void* buffer, void** data,
                                   size_t* used) noexcept
{
    HRESULT hr = TokenResult(async, kTokenIdentity, size, buffer, data, used);
    SAKE_TRACE("%p size %zu -> %#lx", async, size, static_cast<unsigned long>(hr));
    return hr;
}

HRESULT GetTokenAndSignatureUtf16Async(void*, XUserHandle user, uint32_t options, const wchar_t* method,
                                       const wchar_t* url, size_t, const void*, size_t, const void*,
                                       XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%p options %#x %ls %ls", user, options, method ? method : L"", url ? url : L"");
    if (!IsUser(user) || url == nullptr)
        return E_INVALIDARG;
    return RequestToken(async, kTokenUtf16Identity, "XUserGetTokenAndSignatureUtf16Async", Narrow(url), options,
                        Payload::Kind::TokenUtf16);
}

HRESULT GetTokenAndSignatureUtf16Result(void*, XAsyncBlock* async, size_t size, void* buffer, void** data,
                                        size_t* used) noexcept
{
    HRESULT hr = TokenResult(async, kTokenUtf16Identity, size, buffer, data, used);
    SAKE_TRACE("%p size %zu -> %#lx", async, size, static_cast<unsigned long>(hr));
    return hr;
}

HRESULT ResolveIssueWithUiAsync(void*, XUserHandle user, const char* url, XAsyncBlock*) noexcept
{
    SAKE_TRACE("%p %s", user, url ? url : "");
    return E_NOTIMPL;
}

HRESULT ResolveIssueWithUiUtf16Async(void*, XUserHandle user, const wchar_t* url, XAsyncBlock*) noexcept
{
    SAKE_TRACE("%p %ls", user, url ? url : L"");
    return E_NOTIMPL;
}

HRESULT RegisterForChangeEvent(void*, XTaskQueueHandle queue, void* context, void* callback,
                               XTaskQueueRegistrationToken* token) noexcept
{
    SAKE_TRACE("%p", queue);
    if (token == nullptr || callback == nullptr)
        return E_POINTER;
    XTaskQueueHandle kept = nullptr;
    if (queue != nullptr ? FAILED(::XTaskQueueDuplicateHandle(queue, &kept))
                         : !::XTaskQueueGetCurrentProcessTaskQueue(&kept))
        return E_INVALIDARG;
    *token = NextToken();
    AcquireSRWLockExclusive(&g_changeLock);
    g_changes.push_back({kept, context, reinterpret_cast<ChangeCallback>(callback), token->token});
    ReleaseSRWLockExclusive(&g_changeLock);
    return S_OK;
}

bool UnregisterForChangeEvent(void*, XTaskQueueRegistrationToken token, bool) noexcept
{
    SAKE_TRACE("%llu", static_cast<unsigned long long>(token.token));
    XTaskQueueHandle queue = nullptr;
    AcquireSRWLockExclusive(&g_changeLock);
    for (auto registration = g_changes.begin(); registration != g_changes.end(); ++registration) {
        if (registration->token == token.token) {
            queue = registration->queue;
            g_changes.erase(registration);
            break;
        }
    }
    ReleaseSRWLockExclusive(&g_changeLock);
    if (queue != nullptr)
        ::XTaskQueueCloseHandle(queue);
    return true;
}

// Nothing of these is ever delivered, so a registration is a token and nothing else.
HRESULT RegisterChange(void*, XTaskQueueHandle queue, void*, void*, XTaskQueueRegistrationToken* token) noexcept
{
    SAKE_TRACE("%p", queue);
    if (token == nullptr)
        return E_POINTER;
    *token = NextToken();
    return S_OK;
}

bool UnregisterChange(void*, XTaskQueueRegistrationToken token, bool) noexcept
{
    SAKE_TRACE("%llu", static_cast<unsigned long long>(token.token));
    return true;
}

HRESULT GetSignOutDeferral(void*, void** deferral) noexcept
{
    SAKE_TRACE("");
    if (deferral != nullptr)
        *deferral = nullptr;
    return E_GAMEUSER_DEFERRAL_NOT_AVAILABLE;
}

void CloseSignOutDeferralHandle(void*, void* deferral) noexcept
{
    SAKE_TRACE("%p", deferral);
}

// The title passes the XUID PlayFab has linked to its Steam account (docs/gdk.md). Until
// the person is known, the placeholder takes it.
HRESULT AddByIdWithUiAsync(void*, uint64_t id, XAsyncBlock* async) noexcept
{
    bool known = Refresh();
    AcquireSRWLockExclusive(&g_person.lock);
    bool other = known && g_person.session.xuid != id;
    if (!known)
        g_person.placeholderXuid = id;
    ReleaseSRWLockExclusive(&g_person.lock);
    SAKE_TRACE("%s", other ? "not the person the session names" : known ? "the person" : "the placeholder");
    return CompleteNow(async, kAddByIdIdentity, "XUserAddByIdWithUiAsync", other ? E_GAMEUSER_USER_NOT_FOUND : S_OK,
                       UserPayload());
}

HRESULT AddByIdWithUiResult(void*, XAsyncBlock* async, XUserHandle* user) noexcept
{
    if (user != nullptr)
        *user = nullptr;
    HRESULT hr = ::XAsyncGetResult(async, kAddByIdIdentity, sizeof(XUserHandle), user, nullptr);
    SAKE_TRACE("%p -> %#lx", async, static_cast<unsigned long>(hr));
    return hr;
}

HRESULT GetMsaTokenSilentlyAsync(void*, XUserHandle user, uint32_t, const char* scope, XAsyncBlock*) noexcept
{
    SAKE_TRACE("%p %s", user, scope ? scope : "");
    return E_INVALIDARG;
}

HRESULT GetMsaTokenSilentlyResult(void*, XAsyncBlock* async, size_t, char*, size_t*) noexcept
{
    SAKE_TRACE("%p", async);
    return E_INVALIDARG;
}

bool IsStoreUser(void*, XUserHandle user) noexcept
{
    SAKE_TRACE("%p", user);
    return false;
}

HRESULT RemoteConnectSetEventHandlers(void*, XTaskQueueHandle queue, const void* handlers) noexcept
{
    SAKE_TRACE("%p %p", queue, handlers);
    return S_OK;
}

HRESULT RemoteConnectCancelPrompt(void*, void* operation) noexcept
{
    SAKE_TRACE("%p", operation);
    return S_OK;
}

HRESULT SpopPromptSetEventHandlers(void*, XTaskQueueHandle queue, void* handler, void*) noexcept
{
    SAKE_TRACE("%p %p", queue, handler);
    return S_OK;
}

HRESULT SpopPromptComplete(void*, void* operation, uint32_t result) noexcept
{
    SAKE_TRACE("%p %u", operation, result);
    return S_OK;
}

bool IsSignOutPresent(void*) noexcept
{
    SAKE_TRACE("");
    return false;
}

HRESULT SignOutAsync(void*, XUserHandle user, XAsyncBlock*) noexcept
{
    return Unsupported(__func__, user);
}

constexpr XUserVtbl kUserVtbl = {
    .unknown = kUnknown,
    .XUserDuplicateHandle = DuplicateHandle,
    .XUserCloseHandle = CloseHandle,
    .XUserCompare = Compare,
    .XUserGetMaxUsers = GetMaxUsers,
    .XUserAddAsync = AddAsync,
    .XUserAddResult = AddResult,
    .XUserGetLocalId = GetLocalId,
    .XUserFindUserByLocalId = FindUserByLocalId,
    .XUserGetId = GetId,
    .XUserFindUserById = FindUserById,
    .XUserGetIsGuest = GetIsGuest,
    .XUserGetState = GetState,
    .Slot12 = Slot12,
    .XUserGetGamerPictureAsync = GetGamerPictureAsync,
    .XUserGetGamerPictureResultSize = ResultSizeOfNothing,
    .XUserGetGamerPictureResult = GetGamerPictureResult,
    .XUserGetAgeGroup = GetAgeGroup,
    .XUserCheckPrivilege = CheckPrivilege,
    .XUserResolvePrivilegeWithUiAsync = ResolvePrivilegeWithUiAsync,
    .XUserResolvePrivilegeWithUiResult = ResultOfNothing,
    .XUserGetTokenAndSignatureAsync = GetTokenAndSignatureAsync,
    .XUserGetTokenAndSignatureResultSize = GetTokenAndSignatureResultSize,
    .XUserGetTokenAndSignatureResult = GetTokenAndSignatureResult,
    .XUserGetTokenAndSignatureUtf16Async = GetTokenAndSignatureUtf16Async,
    .XUserGetTokenAndSignatureUtf16ResultSize = GetTokenAndSignatureResultSize,
    .XUserGetTokenAndSignatureUtf16Result = GetTokenAndSignatureUtf16Result,
    .XUserResolveIssueWithUiAsync = ResolveIssueWithUiAsync,
    .XUserResolveIssueWithUiResult = ResultOfNothing,
    .XUserResolveIssueWithUiUtf16Async = ResolveIssueWithUiUtf16Async,
    .XUserResolveIssueWithUiUtf16Result = ResultOfNothing,
    .XUserRegisterForChangeEvent = RegisterForChangeEvent,
    .XUserUnregisterForChangeEvent = UnregisterForChangeEvent,
    .XUserGetSignOutDeferral = GetSignOutDeferral,
    .XUserCloseSignOutDeferralHandle = CloseSignOutDeferralHandle,
    .XUserAddByIdWithUiAsync = AddByIdWithUiAsync,
    .XUserAddByIdWithUiResult = AddByIdWithUiResult,
    .XUserGetMsaTokenSilentlyAsync = GetMsaTokenSilentlyAsync,
    .XUserGetMsaTokenSilentlyResult = GetMsaTokenSilentlyResult,
    .XUserGetMsaTokenSilentlyResultSize = ResultSizeOfNothing,
    .XUserIsStoreUser = IsStoreUser,
    .XUserPlatformRemoteConnectSetEventHandlers = RemoteConnectSetEventHandlers,
    .XUserPlatformRemoteConnectCancelPrompt = RemoteConnectCancelPrompt,
    .XUserPlatformSpopPromptSetEventHandlers = SpopPromptSetEventHandlers,
    .XUserPlatformSpopPromptComplete = SpopPromptComplete,
    .XUserIsSignOutPresent = IsSignOutPresent,
    .XUserSignOutAsync = SignOutAsync,
    .XUserSignOutResult = ResultOfNothing,
    .beyond = SAKE_BEYOND(47),
};

// The XSTS claims carry one gamertag, so the classic, modern and unique forms are all it,
// and the suffix is empty, as it is for any gamertag without one.
HRESULT GetGamertag(void*, XUserHandle user, uint32_t component, size_t size, char* gamertag, size_t* used) noexcept
{
    SAKE_TRACE("%p component %u", user, component);
    if (used != nullptr)
        *used = 0;
    if (!IsUser(user) || component > 3)
        return E_INVALIDARG;
    AcquireSRWLockShared(&g_person.lock);
    std::string text = component == 2 || !g_person.known ? std::string() : g_person.session.gamertag;
    ReleaseSRWLockShared(&g_person.lock);
    if (gamertag == nullptr || size < text.size() + 1)
        return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    memcpy(gamertag, text.c_str(), text.size() + 1);
    if (used != nullptr)
        *used = text.size() + 1;
    return S_OK;
}

constexpr XUserGamertagVtbl kGamertagVtbl = {
    .unknown = kUnknown,
    .XUserGetGamertag = GetGamertag,
    .beyond = SAKE_BEYOND(1),
};

HRESULT FindForDevice(void*, const void* device, XUserHandle* user) noexcept
{
    SAKE_TRACE("%p", device);
    if (user != nullptr)
        *user = nullptr;
    return E_GAMEUSER_USER_NOT_FOUND;
}

HRESULT GetDefaultAudioEndpointUtf16(void*, XUserLocalId id, uint32_t kind, size_t, wchar_t*, size_t* used) noexcept
{
    SAKE_TRACE("%llu kind %u", static_cast<unsigned long long>(id.value), kind);
    if (used != nullptr)
        *used = 0;
    return E_GAMEUSER_USER_NOT_FOUND;
}

HRESULT FindControllerForUserWithUiAsync(void*, XUserHandle user, XAsyncBlock*) noexcept
{
    return Unsupported(__func__, user);
}

HRESULT FindControllerForUserWithUiResult(void*, XAsyncBlock* async, void*) noexcept
{
    SAKE_TRACE("%p", async);
    return E_INVALIDARG;
}

constexpr XUserDeviceVtbl kDeviceVtbl = {
    .unknown = kUnknown,
    .XUserFindForDevice = FindForDevice,
    .XUserRegisterForDeviceAssociationChanged = RegisterChange,
    .XUserUnregisterForDeviceAssociationChanged = UnregisterChange,
    .XUserGetDefaultAudioEndpointUtf16 = GetDefaultAudioEndpointUtf16,
    .XUserRegisterForDefaultAudioEndpointUtf16Changed = RegisterChange,
    .XUserUnregisterForDefaultAudioEndpointUtf16Changed = UnregisterChange,
    .XUserFindControllerForUserWithUiAsync = FindControllerForUserWithUiAsync,
    .XUserFindControllerForUserWithUiResult = FindControllerForUserWithUiResult,
    .beyond = SAKE_BEYOND(8),
};

constexpr GUID kUserIids[] = {kXUserClass, kXUser2Iid, kXUser3Iid, kXUser4Iid, kXUser5Iid, kXUser6Iid};
constexpr GUID kGamertagIids[] = {kXUserGamertagIid};
constexpr GUID kDeviceIids[] = {kXUserDeviceClass, kXUserDevice2Iid};

}  // namespace

const Object kXUser = {&kUserVtbl, "XUser", kUserIids, std::size(kUserIids)};
const Object kXUserGamertag = {&kGamertagVtbl, "XUserGamertag", kGamertagIids, std::size(kGamertagIids)};
const Object kXUserDevice = {&kDeviceVtbl, "XUserDevice", kDeviceIids, std::size(kDeviceIids)};

}  // namespace sake
