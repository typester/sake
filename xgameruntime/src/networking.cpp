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

// Nothing here ever changes, so a registration is a token and nothing else.
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
HRESULT GetConnectivityHint(void*, XNetworkingConnectivityHint* hint) noexcept
{
    SAKE_TRACE("");
    if (hint == nullptr)
        return E_POINTER;
    *hint = {kInternetAccess, kUnrestricted, kEthernet, true, false, false, false};
    return S_OK;
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
    .XNetworkingRegisterConnectivityHintChanged = RegisterChange,
    .XNetworkingUnregisterConnectivityHintChanged = UnregisterChange,
    .XNetworkingQueryConfigurationSetting = QueryConfigurationSetting,
    .XNetworkingSetConfigurationSetting = SetConfigurationSetting,
    .XNetworkingQueryStatistics = QueryStatistics,
    .beyond = SAKE_BEYOND(18),
};

constexpr GUID kIids[] = {kXNetworkingClass, kXNetworking2Iid};

}  // namespace

const Object kXNetworking = {&kVtbl, "XNetworking", kIids, std::size(kIids)};

}  // namespace sake
