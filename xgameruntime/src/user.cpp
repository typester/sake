#include "runtime.h"
#include "guids.h"

namespace sake {
namespace {

constexpr uint32_t kAddDefaultUserSilently = 0x1;

// There is no user yet: signing in is the next step (docs/gdk.md). Every add fails, and
// fails through XAsyncBegin, which completes the call when Begin fails. A call that never
// completed would block its queue's termination, and a title waits on that.
HRESULT CALLBACK FailSilentAdd(XAsyncOp op, const XAsyncProviderData*) noexcept
{
    return op == XAsyncOp::Begin ? E_GAMEUSER_NO_DEFAULT_USER : S_OK;
}

// As if the sign-in window had been closed.
HRESULT CALLBACK FailInteractiveAdd(XAsyncOp op, const XAsyncProviderData*) noexcept
{
    return op == XAsyncOp::Begin ? E_ABORT : S_OK;
}

const void* const kAddIdentity = &kAddIdentity;
const void* const kAddByIdIdentity = &kAddByIdIdentity;

HRESULT DuplicateHandle(void*, XUserHandle user, XUserHandle* duplicate) noexcept
{
    SAKE_TRACE("%p", user);
    if (duplicate != nullptr)
        *duplicate = nullptr;
    return E_INVALIDARG;
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

HRESULT AddAsync(void*, uint32_t options, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("options %#x", options);
    return ::XAsyncBegin(async, nullptr, kAddIdentity, "XUserAddAsync",
                         (options & kAddDefaultUserSilently) ? FailSilentAdd : FailInteractiveAdd);
}

HRESULT AddResult(void*, XAsyncBlock* async, XUserHandle* user) noexcept
{
    if (user != nullptr)
        *user = nullptr;
    HRESULT hr = ::XAsyncGetResult(async, kAddIdentity, sizeof(XUserHandle), user, nullptr);
    SAKE_TRACE("%p -> %#lx", async, static_cast<unsigned long>(hr));
    return hr;
}

HRESULT NoUser(const char* call, XUserHandle user) noexcept
{
    SAKE_TRACE("%s %p", call, user);
    return E_INVALIDARG;
}

HRESULT GetLocalId(void*, XUserHandle user, XUserLocalId*) noexcept
{
    return NoUser(__func__, user);
}

HRESULT FindUserByLocalId(void*, XUserLocalId id, XUserHandle* user) noexcept
{
    SAKE_TRACE("%llu", static_cast<unsigned long long>(id.value));
    if (user != nullptr)
        *user = nullptr;
    return E_GAMEUSER_USER_NOT_FOUND;
}

HRESULT GetId(void*, XUserHandle user, uint64_t*) noexcept
{
    return NoUser(__func__, user);
}

HRESULT FindUserById(void*, uint64_t, XUserHandle* user) noexcept
{
    SAKE_TRACE("");
    if (user != nullptr)
        *user = nullptr;
    return E_GAMEUSER_USER_NOT_FOUND;
}

HRESULT GetIsGuest(void*, XUserHandle user, bool*) noexcept
{
    return NoUser(__func__, user);
}

HRESULT GetState(void*, XUserHandle user, uint32_t*) noexcept
{
    return NoUser(__func__, user);
}

HRESULT Slot12(void*) noexcept
{
    SAKE_TRACE("unknown slot 12");
    return kUnknownSlot;
}

HRESULT GetGamerPictureAsync(void*, XUserHandle user, uint32_t, XAsyncBlock*) noexcept
{
    return NoUser(__func__, user);
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

HRESULT GetAgeGroup(void*, XUserHandle user, uint32_t*) noexcept
{
    return NoUser(__func__, user);
}

HRESULT CheckPrivilege(void*, XUserHandle user, uint32_t, uint32_t privilege, bool*, uint32_t*) noexcept
{
    SAKE_TRACE("%p privilege %u", user, privilege);
    return E_INVALIDARG;
}

HRESULT ResolvePrivilegeWithUiAsync(void*, XUserHandle user, uint32_t, uint32_t, XAsyncBlock*) noexcept
{
    return NoUser(__func__, user);
}

HRESULT ResultOfNothing(void*, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%p", async);
    return E_INVALIDARG;
}

HRESULT GetTokenAndSignatureAsync(void*, XUserHandle user, uint32_t, const char* method, const char* url, size_t,
                                  const void*, size_t, const void*, XAsyncBlock*) noexcept
{
    SAKE_TRACE("%p %s %s", user, method ? method : "", url ? url : "");
    return E_INVALIDARG;
}

HRESULT GetTokenAndSignatureResult(void*, XAsyncBlock* async, size_t, void*, void** data, size_t*) noexcept
{
    SAKE_TRACE("%p", async);
    if (data != nullptr)
        *data = nullptr;
    return E_INVALIDARG;
}

HRESULT GetTokenAndSignatureUtf16Async(void*, XUserHandle user, uint32_t, const wchar_t* method,
                                       const wchar_t* url, size_t, const void*, size_t, const void*,
                                       XAsyncBlock*) noexcept
{
    SAKE_TRACE("%p %ls %ls", user, method ? method : L"", url ? url : L"");
    return E_INVALIDARG;
}

HRESULT ResolveIssueWithUiAsync(void*, XUserHandle user, const char* url, XAsyncBlock*) noexcept
{
    SAKE_TRACE("%p %s", user, url ? url : "");
    return E_INVALIDARG;
}

HRESULT ResolveIssueWithUiUtf16Async(void*, XUserHandle user, const wchar_t* url, XAsyncBlock*) noexcept
{
    SAKE_TRACE("%p %ls", user, url ? url : L"");
    return E_INVALIDARG;
}

// No user ever signs in or out yet, so a registration is a token and nothing else.
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

HRESULT AddByIdWithUiAsync(void*, uint64_t, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("");
    return ::XAsyncBegin(async, nullptr, kAddByIdIdentity, "XUserAddByIdWithUiAsync", FailInteractiveAdd);
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
    return NoUser(__func__, user);
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
    .XUserGetTokenAndSignatureResultSize = ResultSizeOfNothing,
    .XUserGetTokenAndSignatureResult = GetTokenAndSignatureResult,
    .XUserGetTokenAndSignatureUtf16Async = GetTokenAndSignatureUtf16Async,
    .XUserGetTokenAndSignatureUtf16ResultSize = ResultSizeOfNothing,
    .XUserGetTokenAndSignatureUtf16Result = GetTokenAndSignatureResult,
    .XUserResolveIssueWithUiAsync = ResolveIssueWithUiAsync,
    .XUserResolveIssueWithUiResult = ResultOfNothing,
    .XUserResolveIssueWithUiUtf16Async = ResolveIssueWithUiUtf16Async,
    .XUserResolveIssueWithUiUtf16Result = ResultOfNothing,
    .XUserRegisterForChangeEvent = RegisterChange,
    .XUserUnregisterForChangeEvent = UnregisterChange,
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

HRESULT GetGamertag(void*, XUserHandle user, uint32_t component, size_t, char*, size_t* used) noexcept
{
    SAKE_TRACE("%p component %u", user, component);
    if (used != nullptr)
        *used = 0;
    return E_INVALIDARG;
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
    return NoUser(__func__, user);
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
