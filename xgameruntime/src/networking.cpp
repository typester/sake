#include "runtime.h"
#include "guids.h"

namespace sake {
namespace {

constexpr uint32_t kInternetAccess = 3;
constexpr uint32_t kUnrestricted = 1;
constexpr uint32_t kEthernet = 6;
constexpr uint32_t kTls12 = 0x00000800;

HRESULT QueryPreferredLocalUdpMultiplayerPort(void*, uint16_t*) noexcept
{
    SAKE_TRACE("not implemented");
    return E_NOTIMPL;
}

HRESULT CALLBACK FailWithNotImplemented(XAsyncOp op, const XAsyncProviderData*) noexcept
{
    return op == XAsyncOp::Begin ? E_NOTIMPL : S_OK;
}

HRESULT QueryPreferredLocalUdpMultiplayerPortAsync(void*, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("not implemented");
    return ::XAsyncBegin(async, nullptr, reinterpret_cast<const void*>(&QueryPreferredLocalUdpMultiplayerPortAsync),
                         __func__, FailWithNotImplemented);
}

HRESULT QueryPreferredLocalUdpMultiplayerPortAsyncResult(void*, XAsyncBlock* async, uint16_t* port) noexcept
{
    SAKE_TRACE("%p", async);
    return ::XAsyncGetResult(async, reinterpret_cast<const void*>(&QueryPreferredLocalUdpMultiplayerPortAsync),
                             sizeof(*port), port, nullptr);
}

// The preferred UDP port never changes, so a registration for it is a token and nothing else.
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

HRESULT CALLBACK SecurityInformation(XAsyncOp op, const XAsyncProviderData* data) noexcept
{
    switch (op) {
    case XAsyncOp::Begin:
        return ::XAsyncSchedule(data->async, 0);
    case XAsyncOp::DoWork:
        ::XAsyncComplete(data->async, S_OK, sizeof(XNetworkingSecurityInformation));
        return S_OK;
    case XAsyncOp::GetResult: {
        if (data->bufferSize < sizeof(XNetworkingSecurityInformation))
            return E_NOT_SUFFICIENT_BUFFER;
        auto* info = static_cast<XNetworkingSecurityInformation*>(data->buffer);
        *info = {kTls12, 0, nullptr};
        return S_OK;
    }
    default:
        return S_OK;
    }
}

const void* const kSecurityInformationIdentity = &kSecurityInformationIdentity;

HRESULT QuerySecurityInformationForUrlAsync(void*, const char* url, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%s", url ? url : "");
    return ::XAsyncBegin(async, nullptr, kSecurityInformationIdentity, __func__, SecurityInformation);
}

HRESULT QuerySecurityInformationForUrlUtf16Async(void*, const wchar_t* url, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%ls", url ? url : L"");
    return ::XAsyncBegin(async, nullptr, kSecurityInformationIdentity, __func__, SecurityInformation);
}

HRESULT QuerySecurityInformationResultSize(void*, XAsyncBlock* async, size_t* size) noexcept
{
    SAKE_TRACE("%p", async);
    return ::XAsyncGetResultSize(async, size);
}

HRESULT QuerySecurityInformationResult(void*, XAsyncBlock* async, size_t size, size_t* used, uint8_t* buffer,
                                       XNetworkingSecurityInformation** info) noexcept
{
    SAKE_TRACE("%p size %zu", async, size);
    HRESULT hr = ::XAsyncGetResult(async, kSecurityInformationIdentity, size, buffer, used);
    if (info != nullptr)
        *info = SUCCEEDED(hr) ? reinterpret_cast<XNetworkingSecurityInformation*>(buffer) : nullptr;
    return hr;
}

HRESULT VerifyServerCertificate(void*, void* request, const XNetworkingSecurityInformation*) noexcept
{
    SAKE_TRACE("%p", request);
    return S_OK;
}

// Nothing here ever sends a change event, so the first answer is the only one a title
// gets: it has to say the network is up.
constexpr XNetworkingConnectivityHint kOnline = {kInternetAccess, kUnrestricted, kEthernet, true, false, false, false};

HRESULT GetConnectivityHint(void*, XNetworkingConnectivityHint* hint) noexcept
{
    SAKE_TRACE("");
    if (hint == nullptr)
        return E_POINTER;
    *hint = kOnline;
    return S_OK;
}

typedef void(CALLBACK* HintCallback)(void* context, const XNetworkingConnectivityHint* hint);

struct HintRegistration {
    XTaskQueueHandle queue;
    uint64_t token;
};

SRWLOCK g_hintLock = SRWLOCK_INIT;
std::vector<HintRegistration> g_hints;

struct HintDelivery {
    HintCallback callback;
    void* context;
    XNetworkingConnectivityHint hint;
};

void CALLBACK DeliverHint(void* context, bool canceled) noexcept
{
    HintDelivery* delivery = static_cast<HintDelivery*>(context);
    if (!canceled)
        delivery->callback(delivery->context, &delivery->hint);
    delete delivery;
}

// Registering sends an initial notification, Microsoft's reference says, and Minecraft
// Dungeons II sent no request until it had one (docs/gdk.md). The community stand-in sends it
// once, on the completion port of the queue the title registered, and so does this.
HRESULT RegisterConnectivityHintChanged(void*, XTaskQueueHandle queue, void* context, void* callback,
                                        XTaskQueueRegistrationToken* token) noexcept
{
    if (token == nullptr || callback == nullptr)
        return E_POINTER;
    XTaskQueueHandle kept = nullptr;
    if (queue != nullptr ? FAILED(::XTaskQueueDuplicateHandle(queue, &kept))
                         : !::XTaskQueueGetCurrentProcessTaskQueue(&kept))
        return E_INVALIDARG;
    *token = NextToken();
    AcquireSRWLockExclusive(&g_hintLock);
    g_hints.push_back({kept, token->token});
    ReleaseSRWLockExclusive(&g_hintLock);

    HRESULT hr = E_OUTOFMEMORY;
    auto* delivery = new (std::nothrow) HintDelivery{reinterpret_cast<HintCallback>(callback), context, kOnline};
    if (delivery != nullptr) {
        hr = ::XTaskQueueSubmitCallback(kept, XTaskQueuePort::Completion, delivery, DeliverHint);
        if (FAILED(hr))
            delete delivery;
    }
    SAKE_TRACE("%p token %llu, initial notification %#lx", queue, static_cast<unsigned long long>(token->token),
               static_cast<unsigned long>(hr));
    return S_OK;
}

bool UnregisterConnectivityHintChanged(void*, XTaskQueueRegistrationToken token, bool) noexcept
{
    SAKE_TRACE("%llu", static_cast<unsigned long long>(token.token));
    XTaskQueueHandle queue = nullptr;
    AcquireSRWLockExclusive(&g_hintLock);
    for (auto registration = g_hints.begin(); registration != g_hints.end(); ++registration) {
        if (registration->token == token.token) {
            queue = registration->queue;
            g_hints.erase(registration);
            break;
        }
    }
    ReleaseSRWLockExclusive(&g_hintLock);
    if (queue != nullptr)
        ::XTaskQueueCloseHandle(queue);
    return true;
}

HRESULT QueryConfigurationSetting(void*, uint32_t setting, uint64_t*) noexcept
{
    SAKE_TRACE("not implemented: %u", setting);
    return E_NOTIMPL;
}

HRESULT SetConfigurationSetting(void*, uint32_t setting, uint64_t value) noexcept
{
    SAKE_TRACE("not implemented: %u = %llu", setting, static_cast<unsigned long long>(value));
    return E_NOTIMPL;
}

HRESULT QueryStatistics(void*, uint32_t type, void*) noexcept
{
    SAKE_TRACE("not implemented: %u", type);
    return E_NOTIMPL;
}

constexpr XNetworkingVtbl kVtbl = {
    .unknown = kUnknown,
    .XNetworkingQueryPreferredLocalUdpMultiplayerPort = QueryPreferredLocalUdpMultiplayerPort,
    .XNetworkingQueryPreferredLocalUdpMultiplayerPortAsync = QueryPreferredLocalUdpMultiplayerPortAsync,
    .XNetworkingQueryPreferredLocalUdpMultiplayerPortAsyncResult = QueryPreferredLocalUdpMultiplayerPortAsyncResult,
    .XNetworkingRegisterPreferredLocalUdpMultiplayerPortChanged = RegisterChange,
    .XNetworkingUnregisterPreferredLocalUdpMultiplayerPortChanged = UnregisterChange,
    .XNetworkingQuerySecurityInformationForUrlAsync = QuerySecurityInformationForUrlAsync,
    .XNetworkingQuerySecurityInformationForUrlAsyncResultSize = QuerySecurityInformationResultSize,
    .XNetworkingQuerySecurityInformationForUrlAsyncResult = QuerySecurityInformationResult,
    .XNetworkingQuerySecurityInformationForUrlUtf16Async = QuerySecurityInformationForUrlUtf16Async,
    .XNetworkingQuerySecurityInformationForUrlUtf16AsyncResultSize = QuerySecurityInformationResultSize,
    .XNetworkingQuerySecurityInformationForUrlUtf16AsyncResult = QuerySecurityInformationResult,
    .XNetworkingVerifyServerCertificate = VerifyServerCertificate,
    .XNetworkingGetConnectivityHint = GetConnectivityHint,
    .XNetworkingRegisterConnectivityHintChanged = RegisterConnectivityHintChanged,
    .XNetworkingUnregisterConnectivityHintChanged = UnregisterConnectivityHintChanged,
    .XNetworkingQueryConfigurationSetting = QueryConfigurationSetting,
    .XNetworkingSetConfigurationSetting = SetConfigurationSetting,
    .XNetworkingQueryStatistics = QueryStatistics,
    .beyond = SAKE_BEYOND(18),
};

constexpr GUID kIids[] = {kXNetworkingClass, kXNetworking2Iid};

}  // namespace

const Object kXNetworking = {&kVtbl, "XNetworking", kIids, std::size(kIids)};

}  // namespace sake
