#include "runtime.h"
#include "guids.h"

#include <cstdlib>

namespace sake {
namespace {

// XGameRuntimeFeature, in the order WineGDK's include/xgameruntimefeature.idl gives.
enum class Feature : uint32_t {
    XAccessibility,
    XAppCapture,
    XAsync,
    XAsyncProvider,
    XDisplay,
    XGame,
    XGameInvite,
    XGameSave,
    XGameUI,
    XLauncher,
    XNetworking,
    XPackage,
    XPersistentLocalStorage,
    XSpeechSynthesizer,
    XStore,
    XSystem,
    XTaskQueue,
    XThread,
    XUser,
    XError,
    XGameEvent,
    XGameStreaming,
};

bool IsFeatureAvailable(void*, uint32_t feature) noexcept
{
    bool available = false;
    switch (static_cast<Feature>(feature)) {
    case Feature::XAsync:
    case Feature::XAsyncProvider:
    case Feature::XGame:
    case Feature::XNetworking:
    case Feature::XSystem:
    case Feature::XTaskQueue:
    case Feature::XThread:
    case Feature::XUser:
    case Feature::XError:
        available = true;
        break;
    default:
        break;
    }
    SAKE_TRACE("%u -> %d", feature, available);
    return available;
}

constexpr XGameRuntimeFeatureVtbl kFeatureVtbl = {
    .unknown = kUnknown,
    .XGameRuntimeIsFeatureAvailable = IsFeatureAvailable,
    .beyond = SAKE_BEYOND(1),
};

void ErrorReport(void*, HRESULT result, const char* message) noexcept
{
    SAKE_TRACE("%#lx %s", static_cast<unsigned long>(result), message ? message : "");
}

void ErrorSetCallback(void*, void* callback, void* context) noexcept
{
    SAKE_TRACE("%p %p", callback, context);
}

void ErrorSetOptions(void*, uint32_t debuggerPresent, uint32_t debuggerNotPresent) noexcept
{
    SAKE_TRACE("%u %u", debuggerPresent, debuggerNotPresent);
}

constexpr XErrorVtbl kErrorVtbl = {
    .unknown = kUnknown,
    .XErrorReport = ErrorReport,
    .XErrorSetCallback = ErrorSetCallback,
    .XErrorSetOptions = ErrorSetOptions,
    .beyond = SAKE_BEYOND(3),
};

HRESULT CopyString(const char* value, size_t size, char* buffer, size_t* used) noexcept
{
    size_t length = strlen(value) + 1;
    if (used != nullptr)
        *used = length;
    if (buffer == nullptr || size < length)
        return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    memcpy(buffer, value, length);
    return S_OK;
}

HRESULT GetConsoleId(void*, size_t, char*, size_t*) noexcept
{
    SAKE_TRACE("not implemented");
    return E_NOTIMPL;
}

HRESULT GetXboxLiveSandboxId(void*, size_t size, char* buffer, size_t* used) noexcept
{
    SAKE_TRACE("size %zu", size);
    return CopyString("RETAIL", size, buffer, used);
}

HRESULT GetAppSpecificDeviceId(void*, size_t, char*, size_t*) noexcept
{
    SAKE_TRACE("not implemented");
    return E_NOTIMPL;
}

HRESULT HandleTrack(void*, void* callback, void* context) noexcept
{
    SAKE_TRACE("%p %p", callback, context);
    return S_OK;
}

bool IsHandleValid(void*, void* handle) noexcept
{
    SAKE_TRACE("%p", handle);
    return handle != nullptr;
}

void AllowFullDownloadBandwidth(void*, bool enable) noexcept
{
    SAKE_TRACE("%d", enable);
}

constexpr XSystemVtbl kSystemVtbl = {
    .unknown = kUnknown,
    .XSystemGetConsoleId = GetConsoleId,
    .XSystemGetXboxLiveSandboxId = GetXboxLiveSandboxId,
    .XSystemGetAppSpecificDeviceId = GetAppSpecificDeviceId,
    .XSystemHandleTrack = HandleTrack,
    .XSystemIsHandleValid = IsHandleValid,
    .XSystemAllowFullDownloadBandwidth = AllowFullDownloadBandwidth,
    .beyond = SAKE_BEYOND(6),
};

XSystemAnalyticsInfo* GetAnalyticsInfo(void*, XSystemAnalyticsInfo* result) noexcept
{
    SAKE_TRACE("%p", result);
    *result = {};

    using RtlGetVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
    OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    auto get = reinterpret_cast<RtlGetVersion>(
        reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion")));
    if (get != nullptr && get(&version) == 0) {
        result->osVersion = {static_cast<uint16_t>(version.dwMajorVersion),
                             static_cast<uint16_t>(version.dwMinorVersion),
                             static_cast<uint16_t>(version.dwBuildNumber), 0};
        result->hostingOsVersion = result->osVersion;
    }
    strcpy_s(result->family, "Windows.Desktop");
    strcpy_s(result->form, "Desktop");
    return result;
}

constexpr XSystemAnalyticsVtbl kAnalyticsVtbl = {
    .unknown = kUnknown,
    .XSystemGetAnalyticsInfo = GetAnalyticsInfo,
    .beyond = SAKE_BEYOND(1),
};

// The title ID a GDK title declares in the MicrosoftGame.config at the root of its
// install, which may be several directories above the executable.
uint32_t TitleIdFromConfig() noexcept
{
    wchar_t path[MAX_PATH];
    DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (length == 0 || length >= MAX_PATH)
        return 0;

    for (int level = 0; level < 5; ++level) {
        wchar_t* slash = wcsrchr(path, L'\\');
        if (slash == nullptr)
            return 0;
        *slash = L'\0';

        wchar_t config[MAX_PATH];
        if (swprintf(config, MAX_PATH, L"%ls\\MicrosoftGame.config", path) < 0)
            return 0;
        HANDLE file = CreateFileW(config, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
            continue;

        char text[16384];
        DWORD read = 0;
        BOOL ok = ReadFile(file, text, sizeof(text) - 1, &read, nullptr);
        ::CloseHandle(file);
        if (!ok)
            return 0;
        text[read] = '\0';

        const char* tag = strstr(text, "<TitleId>");
        if (tag == nullptr)
            return 0;
        uint32_t id = static_cast<uint32_t>(strtoul(tag + strlen("<TitleId>"), nullptr, 16));
        Log("title ID %08X from %ls", id, config);
        return id;
    }
    return 0;
}

HRESULT GetXboxTitleId(void*, uint32_t* titleId) noexcept
{
    const uint32_t id = TitleId();
    SAKE_TRACE("-> %08X", id);
    if (titleId == nullptr)
        return E_POINTER;
    if (id == 0)
        return E_GAMEUSER_NO_TITLE_ID;
    *titleId = id;
    return S_OK;
}

void LaunchNewGame(void*, const char* exePath, const char* args, XUserHandle) noexcept
{
    SAKE_TRACE("not implemented: %s %s", exePath ? exePath : "", args ? args : "");
}

HRESULT LaunchRestartOnCrash(void*, const char* args, uint32_t) noexcept
{
    SAKE_TRACE("%s", args ? args : "");
    return S_OK;
}

constexpr XGameVtbl kGameVtbl = {
    .unknown = kUnknown,
    .XGameGetXboxTitleId = GetXboxTitleId,
    .XLaunchNewGame = LaunchNewGame,
    .XLaunchRestartOnCrash = LaunchRestartOnCrash,
    .beyond = SAKE_BEYOND(3),
};

// Nothing here ever fires an event, so a registration is a token and nothing else.
HRESULT Register(void* self, XTaskQueueHandle queue, void*, void*, XTaskQueueRegistrationToken* token) noexcept
{
    SAKE_TRACE("%s %p", static_cast<Object*>(self)->name, queue);
    if (token == nullptr)
        return E_POINTER;
    *token = NextToken();
    return S_OK;
}

bool Unregister(void* self, XTaskQueueRegistrationToken token, bool) noexcept
{
    SAKE_TRACE("%s %llu", static_cast<Object*>(self)->name, static_cast<unsigned long long>(token.token));
    return true;
}

constexpr RegistrationVtbl kRegistrationVtbl = {
    .unknown = kUnknown,
    .Register = Register,
    .Unregister = Unregister,
    .beyond = SAKE_BEYOND(2),
};

constexpr GUID kFeatureIids[] = {kXGameRuntimeFeatureClass};
constexpr GUID kErrorIids[] = {kXErrorClass};
constexpr GUID kSystemIids[] = {kXSystemClass, kXSystem2Iid, kXSystem3Iid, kXSystem4Iid, kXSystem5Iid};
constexpr GUID kAnalyticsIids[] = {kXSystemAnalyticsClass};
constexpr GUID kGameIids[] = {kXGameClass, kXGameIid};
constexpr GUID kRegistration0651aae2Iids[] = {kRegistration0651aae2Class};
constexpr GUID kRegistration95fd18d2Iids[] = {kRegistration95fd18d2Class, kRegistration95fd18d2Iid};

}  // namespace

uint32_t TitleId() noexcept
{
    static const uint32_t id = TitleIdFromConfig();
    return id;
}

const Object kXGameRuntimeFeature ={&kFeatureVtbl, "XGameRuntimeFeature", kFeatureIids, std::size(kFeatureIids)};
const Object kXError = {&kErrorVtbl, "XError", kErrorIids, std::size(kErrorIids)};
const Object kXSystem = {&kSystemVtbl, "XSystem", kSystemIids, std::size(kSystemIids)};
const Object kXSystemAnalytics = {&kAnalyticsVtbl, "XSystemAnalytics", kAnalyticsIids, std::size(kAnalyticsIids)};
const Object kXGame = {&kGameVtbl, "XGame", kGameIids, std::size(kGameIids)};
const Object kRegistration0651aae2 = {&kRegistrationVtbl, "registration 0651aae2", kRegistration0651aae2Iids,
                                      std::size(kRegistration0651aae2Iids)};
const Object kRegistration95fd18d2 = {&kRegistrationVtbl, "registration 95fd18d2", kRegistration95fd18d2Iids,
                                      std::size(kRegistration95fd18d2Iids)};

}  // namespace sake
