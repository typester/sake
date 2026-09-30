#pragma once

#include "pch.h"

#include <string>

namespace sake {

void Log(const char* format, ...) noexcept __attribute__((format(printf, 1, 2)));
void FormatGuid(const GUID& guid, char (&out)[40]) noexcept;

// The thunks query the runtime on every API call, and a game polls some calls millions of
// times, so each call site writes its first twenty calls and then every power of two.
#define SAKE_TRACE(format, ...)                                                     \
    do {                                                                            \
        static std::atomic<uint32_t> sake_calls_;                                   \
        uint32_t sake_n_ = ++sake_calls_;                                           \
        if (sake_n_ <= 20 || (sake_n_ & (sake_n_ - 1)) == 0)                        \
            ::sake::Log("%s #%u " format, __func__, sake_n_ __VA_OPT__(,) __VA_ARGS__); \
    } while (0)

constexpr HRESULT E_GAMEUSER_RESOLVE_USER_ISSUE_REQUIRED = static_cast<HRESULT>(0x89245102);
constexpr HRESULT E_GAMEUSER_USER_NOT_FOUND = static_cast<HRESULT>(0x89245104);
constexpr HRESULT E_GAMEUSER_NO_TOKEN_REQUIRED = static_cast<HRESULT>(0x89245105);
constexpr HRESULT E_GAMEUSER_DEFERRAL_NOT_AVAILABLE = static_cast<HRESULT>(0x89245103);
constexpr HRESULT E_GAMEUSER_NO_DEFAULT_USER = static_cast<HRESULT>(0x89245106);
constexpr HRESULT E_GAMEUSER_NO_TITLE_ID = static_cast<HRESULT>(0x89245108);

// What a slot whose return type is not known answers. Its low byte is zero on purpose: the
// slot may return a BOOLEAN, and E_NOTIMPL (0x80004001) would read there as true.
constexpr HRESULT kUnknownSlot = static_cast<HRESULT>(0x89240100);

XTaskQueueRegistrationToken NextToken() noexcept;

// From the title's MicrosoftGame.config, or 0 when there is none.
uint32_t TitleId() noexcept;


// Every object is a static singleton whose first member is its vtable, which is the whole
// of COM's layout. The vtables are structs of function pointers rather than C++ virtual
// classes, because clang's mingw target does not lay out or call virtual methods the way
// the MSVC-built thunks do (a struct return, for one, comes back through a different
// register).
struct Object {
    const void* vtbl;
    const char* name;
    const GUID* iids;
    size_t iidCount;
};

struct Unknown {
    HRESULT (*QueryInterface)(void* self, const GUID* iid, void** out) noexcept;
    ULONG (*AddRef)(void* self) noexcept;
    ULONG (*Release)(void* self) noexcept;
};

HRESULT ObjectQueryInterface(void* self, const GUID* iid, void** out) noexcept;
ULONG ObjectAddRef(void* self) noexcept;
ULONG ObjectRelease(void* self) noexcept;
inline constexpr Unknown kUnknown = {ObjectQueryInterface, ObjectAddRef, ObjectRelease};

bool Answers(const Object& object, const GUID& iid) noexcept;

template <int Slot>
HRESULT Beyond(void* self) noexcept
{
    Log("%s: slot %d is past the end of every interface version it answers",
        static_cast<Object*>(self)->name, Slot);
    return kUnknownSlot;
}

// Room past the last known slot, so that a version with a method nobody has described
// logs instead of calling through whatever follows the table.
using BeyondSlots = HRESULT (*[8])(void*) noexcept;
#define SAKE_BEYOND(n)                                                                  \
    {                                                                                   \
        ::sake::Beyond<n>, ::sake::Beyond<n + 1>, ::sake::Beyond<n + 2>,               \
            ::sake::Beyond<n + 3>, ::sake::Beyond<n + 4>, ::sake::Beyond<n + 5>,       \
            ::sake::Beyond<n + 6>, ::sake::Beyond<n + 7>                                \
    }

typedef struct XUser* XUserHandle;

struct XUserLocalId {
    uint64_t value;
};

// What an XUser call hands back once it completes: nothing, the user's handle, or a token
// laid out the way XUserGetTokenAndSignatureData, or its UTF-16 twin, lays one out.
struct Payload {
    enum class Kind { None, User, Token, TokenUtf16 };
    Kind kind = Kind::None;
    XUserHandle user = nullptr;
    std::string token;

    size_t Size() const noexcept;
    void Write(void* buffer) const noexcept;
};

// Completes `async` inside Begin, so that nothing of it is ever queued on the caller's queue.
HRESULT CompleteNow(XAsyncBlock* async, const void* identity, const char* identityName, HRESULT result,
                    Payload payload) noexcept;

// Asks sake to sign the person in, through the files docs/gdk.md describes, and completes
// `async` with what `finish` makes of the answer's state: signed-in, failed, cancelled,
// unanswered or timed out.
using Finish = std::function<HRESULT(const char* state, Payload& payload)>;
HRESULT AskSake(XAsyncBlock* async, const void* identity, const char* identityName, Finish finish) noexcept;

// This title's session, as sake last wrote it.
struct Session {
    struct Token {
        std::string relyingParty;
        uint64_t notAfter = 0;
        std::string value;
    };
    struct Endpoint {
        std::string host;
        std::string relyingParty;
    };
    uint64_t xuid = 0;
    std::string gamertag;
    std::string userHash;
    std::string ageGroup;
    std::string privileges;
    std::vector<Token> tokens;
    std::vector<Endpoint> endpoints;

    // The token for `url`, or nullptr; `covered` says whether any relying party covers the
    // URL's host at all.
    const Token* TokenFor(const char* url, bool* covered) const noexcept;
    const Token* Named(const char* relyingParty) const noexcept;
};

// False when there is no session, or none this runtime can use.
bool ReadSession(Session& session) noexcept;

// Seconds since 1970, which is how sake writes a token's expiry.
uint64_t Now() noexcept;

struct XVersion {
    uint16_t major;
    uint16_t minor;
    uint16_t build;
    uint16_t revision;
};

struct XSystemAnalyticsInfo {
    XVersion osVersion;
    XVersion hostingOsVersion;
    char family[64];
    char form[64];
};
static_assert(sizeof(XSystemAnalyticsInfo) == 0x90);

struct XNetworkingConnectivityHint {
    uint32_t connectivityLevel;
    uint32_t connectivityCost;
    uint32_t ianaInterfaceType;
    bool networkInitialized;
    bool approachingDataLimit;
    bool overDataLimit;
    bool roaming;
};
static_assert(sizeof(XNetworkingConnectivityHint) == 16);

struct XNetworkingThumbprint {
    uint32_t thumbprintType;
    size_t thumbprintBufferByteCount;
    uint8_t* thumbprintBuffer;
};

struct XNetworkingSecurityInformation {
    uint32_t enabledHttpSecurityProtocolFlags;
    size_t thumbprintCount;
    XNetworkingThumbprint* thumbprints;
};
static_assert(sizeof(XNetworkingSecurityInformation) == 24);

// Slot order is WineGDK's (Weather-OS/WineGDK b03ba49, include/xasyncprovider.idl),
// checked against the argument shapes of Minecraft Dungeons II's thunks.
struct XThreadingVtbl {
    Unknown unknown;
    HRESULT (*XAsyncGetStatus)(void*, XAsyncBlock*, bool wait) noexcept;
    HRESULT (*XAsyncGetResultSize)(void*, XAsyncBlock*, size_t*) noexcept;
    void (*XAsyncCancel)(void*, XAsyncBlock*) noexcept;
    HRESULT (*XAsyncRun)(void*, XAsyncBlock*, XAsyncWork*) noexcept;
    HRESULT (*XAsyncBegin)(void*, XAsyncBlock*, void*, const void*, const char*, XAsyncProvider*) noexcept;
    HRESULT (*Slot5)(void*) noexcept;
    HRESULT (*XAsyncSchedule)(void*, XAsyncBlock*, uint32_t) noexcept;
    void (*XAsyncComplete)(void*, XAsyncBlock*, HRESULT, size_t) noexcept;
    HRESULT (*XAsyncGetResult)(void*, XAsyncBlock*, const void*, size_t, void*, size_t*) noexcept;
    HRESULT (*XTaskQueueCreate)(void*, XTaskQueueDispatchMode, XTaskQueueDispatchMode, XTaskQueueHandle*) noexcept;
    HRESULT (*XTaskQueueCreateComposite)(void*, XTaskQueuePortHandle, XTaskQueuePortHandle, XTaskQueueHandle*) noexcept;
    HRESULT (*XTaskQueueGetPort)(void*, XTaskQueueHandle, XTaskQueuePort, XTaskQueuePortHandle*) noexcept;
    HRESULT (*XTaskQueueDuplicateHandle)(void*, XTaskQueueHandle, XTaskQueueHandle*) noexcept;
    bool (*XTaskQueueDispatch)(void*, XTaskQueueHandle, XTaskQueuePort, uint32_t) noexcept;
    void (*XTaskQueueCloseHandle)(void*, XTaskQueueHandle) noexcept;
    HRESULT (*XTaskQueueSubmitCallback)(void*, XTaskQueueHandle, XTaskQueuePort, void*, XTaskQueueCallback*) noexcept;
    HRESULT (*XTaskQueueSubmitDelayedCallback)(void*, XTaskQueueHandle, XTaskQueuePort, uint32_t, void*, XTaskQueueCallback*) noexcept;
    HRESULT (*XTaskQueueRegisterWaiter)(void*, XTaskQueueHandle, XTaskQueuePort, HANDLE, void*, XTaskQueueCallback*, XTaskQueueRegistrationToken*) noexcept;
    void (*XTaskQueueUnregisterWaiter)(void*, XTaskQueueHandle, XTaskQueueRegistrationToken) noexcept;
    HRESULT (*XTaskQueueTerminate)(void*, XTaskQueueHandle, bool wait, void*, XTaskQueueTerminatedCallback*) noexcept;
    HRESULT (*XTaskQueueRegisterMonitor)(void*, XTaskQueueHandle, void*, XTaskQueueMonitorCallback*, XTaskQueueRegistrationToken*) noexcept;
    void (*XTaskQueueUnregisterMonitor)(void*, XTaskQueueHandle, XTaskQueueRegistrationToken) noexcept;
    bool (*XTaskQueueGetCurrentProcessTaskQueue)(void*, XTaskQueueHandle*) noexcept;
    void (*XTaskQueueSetCurrentProcessTaskQueue)(void*, XTaskQueueHandle) noexcept;
    HRESULT (*XThreadSetTimeSensitive)(void*, bool) noexcept;
    HRESULT (*Slot25)(void*) noexcept;
    void (*XThreadAssertNotTimeSensitive)(void*) noexcept;
    bool (*XThreadIsTimeSensitive)(void*) noexcept;
    BeyondSlots beyond;
};

struct XGameRuntimeFeatureVtbl {
    Unknown unknown;
    bool (*XGameRuntimeIsFeatureAvailable)(void*, uint32_t feature) noexcept;
    BeyondSlots beyond;
};

// Not in WineGDK. The slots are read from the thunks' argument shapes, and the names from
// the order the game calls them in.
struct XErrorVtbl {
    Unknown unknown;
    void (*XErrorReport)(void*, HRESULT, const char*) noexcept;
    void (*XErrorSetCallback)(void*, void* callback, void* context) noexcept;
    void (*XErrorSetOptions)(void*, uint32_t debuggerPresent, uint32_t debuggerNotPresent) noexcept;
    BeyondSlots beyond;
};

struct XSystemVtbl {
    Unknown unknown;
    HRESULT (*XSystemGetConsoleId)(void*, size_t, char*, size_t*) noexcept;
    HRESULT (*XSystemGetXboxLiveSandboxId)(void*, size_t, char*, size_t*) noexcept;
    HRESULT (*XSystemGetAppSpecificDeviceId)(void*, size_t, char*, size_t*) noexcept;
    HRESULT (*XSystemHandleTrack)(void*, void* callback, void* context) noexcept;
    bool (*XSystemIsHandleValid)(void*, void* handle) noexcept;
    void (*XSystemAllowFullDownloadBandwidth)(void*, bool) noexcept;
    BeyondSlots beyond;
};

struct XSystemAnalyticsVtbl {
    Unknown unknown;
    // Called as an MSVC member function returning a struct: the buffer comes after self,
    // and its address goes back in RAX.
    XSystemAnalyticsInfo* (*XSystemGetAnalyticsInfo)(void*, XSystemAnalyticsInfo* result) noexcept;
    BeyondSlots beyond;
};

struct XNetworkingVtbl {
    Unknown unknown;
    HRESULT (*XNetworkingQueryPreferredLocalUdpMultiplayerPort)(void*, uint16_t*) noexcept;
    HRESULT (*XNetworkingQueryPreferredLocalUdpMultiplayerPortAsync)(void*, XAsyncBlock*) noexcept;
    HRESULT (*XNetworkingQueryPreferredLocalUdpMultiplayerPortAsyncResult)(void*, XAsyncBlock*, uint16_t*) noexcept;
    HRESULT (*XNetworkingRegisterPreferredLocalUdpMultiplayerPortChanged)(void*, XTaskQueueHandle, void*, void*, XTaskQueueRegistrationToken*) noexcept;
    bool (*XNetworkingUnregisterPreferredLocalUdpMultiplayerPortChanged)(void*, XTaskQueueRegistrationToken, bool wait) noexcept;
    HRESULT (*XNetworkingQuerySecurityInformationForUrlAsync)(void*, const char*, XAsyncBlock*) noexcept;
    HRESULT (*XNetworkingQuerySecurityInformationForUrlAsyncResultSize)(void*, XAsyncBlock*, size_t*) noexcept;
    HRESULT (*XNetworkingQuerySecurityInformationForUrlAsyncResult)(void*, XAsyncBlock*, size_t, size_t*, uint8_t*, XNetworkingSecurityInformation**) noexcept;
    HRESULT (*XNetworkingQuerySecurityInformationForUrlUtf16Async)(void*, const wchar_t*, XAsyncBlock*) noexcept;
    HRESULT (*XNetworkingQuerySecurityInformationForUrlUtf16AsyncResultSize)(void*, XAsyncBlock*, size_t*) noexcept;
    HRESULT (*XNetworkingQuerySecurityInformationForUrlUtf16AsyncResult)(void*, XAsyncBlock*, size_t, size_t*, uint8_t*, XNetworkingSecurityInformation**) noexcept;
    HRESULT (*XNetworkingVerifyServerCertificate)(void*, void* request, const XNetworkingSecurityInformation*) noexcept;
    HRESULT (*XNetworkingGetConnectivityHint)(void*, XNetworkingConnectivityHint*) noexcept;
    HRESULT (*XNetworkingRegisterConnectivityHintChanged)(void*, XTaskQueueHandle, void*, void*, XTaskQueueRegistrationToken*) noexcept;
    bool (*XNetworkingUnregisterConnectivityHintChanged)(void*, XTaskQueueRegistrationToken, bool wait) noexcept;
    HRESULT (*XNetworkingQueryConfigurationSetting)(void*, uint32_t, uint64_t*) noexcept;
    HRESULT (*XNetworkingSetConfigurationSetting)(void*, uint32_t, uint64_t) noexcept;
    HRESULT (*XNetworkingQueryStatistics)(void*, uint32_t, void*) noexcept;
    BeyondSlots beyond;
};

struct XUserVtbl {
    Unknown unknown;
    HRESULT (*XUserDuplicateHandle)(void*, XUserHandle, XUserHandle*) noexcept;
    void (*XUserCloseHandle)(void*, XUserHandle) noexcept;
    int32_t (*XUserCompare)(void*, XUserHandle, XUserHandle) noexcept;
    HRESULT (*XUserGetMaxUsers)(void*, uint32_t*) noexcept;
    HRESULT (*XUserAddAsync)(void*, uint32_t options, XAsyncBlock*) noexcept;
    HRESULT (*XUserAddResult)(void*, XAsyncBlock*, XUserHandle*) noexcept;
    HRESULT (*XUserGetLocalId)(void*, XUserHandle, XUserLocalId*) noexcept;
    HRESULT (*XUserFindUserByLocalId)(void*, XUserLocalId, XUserHandle*) noexcept;
    HRESULT (*XUserGetId)(void*, XUserHandle, uint64_t*) noexcept;
    HRESULT (*XUserFindUserById)(void*, uint64_t, XUserHandle*) noexcept;
    HRESULT (*XUserGetIsGuest)(void*, XUserHandle, bool*) noexcept;
    HRESULT (*XUserGetState)(void*, XUserHandle, uint32_t*) noexcept;
    HRESULT (*Slot12)(void*) noexcept;
    HRESULT (*XUserGetGamerPictureAsync)(void*, XUserHandle, uint32_t, XAsyncBlock*) noexcept;
    HRESULT (*XUserGetGamerPictureResultSize)(void*, XAsyncBlock*, size_t*) noexcept;
    HRESULT (*XUserGetGamerPictureResult)(void*, XAsyncBlock*, size_t, void*, size_t*) noexcept;
    HRESULT (*XUserGetAgeGroup)(void*, XUserHandle, uint32_t*) noexcept;
    HRESULT (*XUserCheckPrivilege)(void*, XUserHandle, uint32_t, uint32_t, bool*, uint32_t*) noexcept;
    HRESULT (*XUserResolvePrivilegeWithUiAsync)(void*, XUserHandle, uint32_t, uint32_t, XAsyncBlock*) noexcept;
    HRESULT (*XUserResolvePrivilegeWithUiResult)(void*, XAsyncBlock*) noexcept;
    HRESULT (*XUserGetTokenAndSignatureAsync)(void*, XUserHandle, uint32_t, const char*, const char*, size_t, const void*, size_t, const void*, XAsyncBlock*) noexcept;
    HRESULT (*XUserGetTokenAndSignatureResultSize)(void*, XAsyncBlock*, size_t*) noexcept;
    HRESULT (*XUserGetTokenAndSignatureResult)(void*, XAsyncBlock*, size_t, void*, void**, size_t*) noexcept;
    HRESULT (*XUserGetTokenAndSignatureUtf16Async)(void*, XUserHandle, uint32_t, const wchar_t*, const wchar_t*, size_t, const void*, size_t, const void*, XAsyncBlock*) noexcept;
    HRESULT (*XUserGetTokenAndSignatureUtf16ResultSize)(void*, XAsyncBlock*, size_t*) noexcept;
    HRESULT (*XUserGetTokenAndSignatureUtf16Result)(void*, XAsyncBlock*, size_t, void*, void**, size_t*) noexcept;
    HRESULT (*XUserResolveIssueWithUiAsync)(void*, XUserHandle, const char*, XAsyncBlock*) noexcept;
    HRESULT (*XUserResolveIssueWithUiResult)(void*, XAsyncBlock*) noexcept;
    HRESULT (*XUserResolveIssueWithUiUtf16Async)(void*, XUserHandle, const wchar_t*, XAsyncBlock*) noexcept;
    HRESULT (*XUserResolveIssueWithUiUtf16Result)(void*, XAsyncBlock*) noexcept;
    HRESULT (*XUserRegisterForChangeEvent)(void*, XTaskQueueHandle, void*, void*, XTaskQueueRegistrationToken*) noexcept;
    bool (*XUserUnregisterForChangeEvent)(void*, XTaskQueueRegistrationToken, bool wait) noexcept;
    HRESULT (*XUserGetSignOutDeferral)(void*, void**) noexcept;
    void (*XUserCloseSignOutDeferralHandle)(void*, void*) noexcept;
    HRESULT (*XUserAddByIdWithUiAsync)(void*, uint64_t, XAsyncBlock*) noexcept;
    HRESULT (*XUserAddByIdWithUiResult)(void*, XAsyncBlock*, XUserHandle*) noexcept;
    HRESULT (*XUserGetMsaTokenSilentlyAsync)(void*, XUserHandle, uint32_t, const char*, XAsyncBlock*) noexcept;
    HRESULT (*XUserGetMsaTokenSilentlyResult)(void*, XAsyncBlock*, size_t, char*, size_t*) noexcept;
    HRESULT (*XUserGetMsaTokenSilentlyResultSize)(void*, XAsyncBlock*, size_t*) noexcept;
    bool (*XUserIsStoreUser)(void*, XUserHandle) noexcept;
    HRESULT (*XUserPlatformRemoteConnectSetEventHandlers)(void*, XTaskQueueHandle, const void*) noexcept;
    HRESULT (*XUserPlatformRemoteConnectCancelPrompt)(void*, void*) noexcept;
    HRESULT (*XUserPlatformSpopPromptSetEventHandlers)(void*, XTaskQueueHandle, void*, void*) noexcept;
    HRESULT (*XUserPlatformSpopPromptComplete)(void*, void*, uint32_t) noexcept;
    bool (*XUserIsSignOutPresent)(void*) noexcept;
    HRESULT (*XUserSignOutAsync)(void*, XUserHandle, XAsyncBlock*) noexcept;
    HRESULT (*XUserSignOutResult)(void*, XAsyncBlock*) noexcept;
    BeyondSlots beyond;
};

struct XUserGamertagVtbl {
    Unknown unknown;
    HRESULT (*XUserGetGamertag)(void*, XUserHandle, uint32_t, size_t, char*, size_t*) noexcept;
    BeyondSlots beyond;
};

struct XUserDeviceVtbl {
    Unknown unknown;
    HRESULT (*XUserFindForDevice)(void*, const void* deviceId, XUserHandle*) noexcept;
    HRESULT (*XUserRegisterForDeviceAssociationChanged)(void*, XTaskQueueHandle, void*, void*, XTaskQueueRegistrationToken*) noexcept;
    bool (*XUserUnregisterForDeviceAssociationChanged)(void*, XTaskQueueRegistrationToken, bool wait) noexcept;
    HRESULT (*XUserGetDefaultAudioEndpointUtf16)(void*, XUserLocalId, uint32_t, size_t, wchar_t*, size_t*) noexcept;
    HRESULT (*XUserRegisterForDefaultAudioEndpointUtf16Changed)(void*, XTaskQueueHandle, void*, void*, XTaskQueueRegistrationToken*) noexcept;
    bool (*XUserUnregisterForDefaultAudioEndpointUtf16Changed)(void*, XTaskQueueRegistrationToken, bool wait) noexcept;
    HRESULT (*XUserFindControllerForUserWithUiAsync)(void*, XUserHandle, XAsyncBlock*) noexcept;
    HRESULT (*XUserFindControllerForUserWithUiResult)(void*, XAsyncBlock*, void* deviceId) noexcept;
    BeyondSlots beyond;
};

// Not in WineGDK either; the slots are read from the thunks.
struct XGameVtbl {
    Unknown unknown;
    HRESULT (*XGameGetXboxTitleId)(void*, uint32_t*) noexcept;
    void (*XLaunchNewGame)(void*, const char* exePath, const char* args, XUserHandle) noexcept;
    HRESULT (*XLaunchRestartOnCrash)(void*, const char* args, uint32_t reserved) noexcept;
    BeyondSlots beyond;
};

// XGameProtocol and XGameInvite have this same shape, and which class is which has not
// been told apart yet.
struct RegistrationVtbl {
    Unknown unknown;
    HRESULT (*Register)(void*, XTaskQueueHandle, void* context, void* callback, XTaskQueueRegistrationToken*) noexcept;
    bool (*Unregister)(void*, XTaskQueueRegistrationToken, bool wait) noexcept;
    BeyondSlots beyond;
};

extern const Object kXThreading;
extern const Object kXGameRuntimeFeature;
extern const Object kXError;
extern const Object kXSystem;
extern const Object kXSystemAnalytics;
extern const Object kXNetworking;
extern const Object kXUser;
extern const Object kXUserGamertag;
extern const Object kXUserDevice;
extern const Object kXGame;
extern const Object kRegistration0651aae2;
extern const Object kRegistration95fd18d2;

}  // namespace sake
