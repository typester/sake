#include "runtime.h"
#include "guids.h"

namespace sake {
namespace {

thread_local bool t_timeSensitive;

HRESULT GetStatus(void*, XAsyncBlock* async, bool wait) noexcept
{
    SAKE_TRACE("%p wait %d", async, wait);
    return ::XAsyncGetStatus(async, wait);
}

HRESULT GetResultSize(void*, XAsyncBlock* async, size_t* size) noexcept
{
    SAKE_TRACE("%p", async);
    return ::XAsyncGetResultSize(async, size);
}

void Cancel(void*, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%p", async);
    ::XAsyncCancel(async);
}

HRESULT Run(void*, XAsyncBlock* async, XAsyncWork* work) noexcept
{
    SAKE_TRACE("%p", async);
    return ::XAsyncRun(async, work);
}

HRESULT Begin(void*, XAsyncBlock* async, void* context, const void* identity, const char* identityName,
              XAsyncProvider* provider) noexcept
{
    SAKE_TRACE("%p %s", async, identityName ? identityName : "");
    return ::XAsyncBegin(async, context, identity, identityName, provider);
}

HRESULT Slot5(void*) noexcept
{
    SAKE_TRACE("unknown slot 5");
    return kUnknownSlot;
}

HRESULT Schedule(void*, XAsyncBlock* async, uint32_t delay) noexcept
{
    SAKE_TRACE("%p delay %u", async, delay);
    return ::XAsyncSchedule(async, delay);
}

void Complete(void*, XAsyncBlock* async, HRESULT result, size_t size) noexcept
{
    SAKE_TRACE("%p %#lx size %zu", async, static_cast<unsigned long>(result), size);
    ::XAsyncComplete(async, result, size);
}

HRESULT GetResult(void*, XAsyncBlock* async, const void* identity, size_t size, void* buffer,
                  size_t* used) noexcept
{
    SAKE_TRACE("%p size %zu", async, size);
    return ::XAsyncGetResult(async, identity, size, buffer, used);
}

HRESULT Create(void*, XTaskQueueDispatchMode work, XTaskQueueDispatchMode completion,
               XTaskQueueHandle* queue) noexcept
{
    HRESULT hr = ::XTaskQueueCreate(work, completion, queue);
    SAKE_TRACE("work %u completion %u -> %#lx %p", static_cast<unsigned>(work),
               static_cast<unsigned>(completion), static_cast<unsigned long>(hr), queue ? *queue : nullptr);
    return hr;
}

HRESULT CreateComposite(void*, XTaskQueuePortHandle work, XTaskQueuePortHandle completion,
                        XTaskQueueHandle* queue) noexcept
{
    HRESULT hr = ::XTaskQueueCreateComposite(work, completion, queue);
    SAKE_TRACE("%p %p -> %#lx %p", work, completion, static_cast<unsigned long>(hr), queue ? *queue : nullptr);
    return hr;
}

// libHttpClient dereferences a queue handle without checking it for null, so a null queue
// is refused here rather than taking the game down.
HRESULT GetPort(void*, XTaskQueueHandle queue, XTaskQueuePort port, XTaskQueuePortHandle* handle) noexcept
{
    SAKE_TRACE("%p port %u", queue, static_cast<unsigned>(port));
    if (queue == nullptr)
        return E_GAMERUNTIME_INVALID_HANDLE;
    return ::XTaskQueueGetPort(queue, port, handle);
}

HRESULT DuplicateHandle(void*, XTaskQueueHandle queue, XTaskQueueHandle* duplicate) noexcept
{
    SAKE_TRACE("%p", queue);
    if (queue == nullptr)
        return E_GAMERUNTIME_INVALID_HANDLE;
    return ::XTaskQueueDuplicateHandle(queue, duplicate);
}

bool Dispatch(void*, XTaskQueueHandle queue, XTaskQueuePort port, uint32_t timeout) noexcept
{
    SAKE_TRACE("%p port %u timeout %u", queue, static_cast<unsigned>(port), timeout);
    if (queue == nullptr)
        return false;
    return ::XTaskQueueDispatch(queue, port, timeout);
}

void CloseHandle(void*, XTaskQueueHandle queue) noexcept
{
    SAKE_TRACE("%p", queue);
    if (queue != nullptr)
        ::XTaskQueueCloseHandle(queue);
}

HRESULT SubmitCallback(void*, XTaskQueueHandle queue, XTaskQueuePort port, void* context,
                       XTaskQueueCallback* callback) noexcept
{
    SAKE_TRACE("%p port %u", queue, static_cast<unsigned>(port));
    if (queue == nullptr)
        return E_GAMERUNTIME_INVALID_HANDLE;
    return ::XTaskQueueSubmitCallback(queue, port, context, callback);
}

HRESULT SubmitDelayedCallback(void*, XTaskQueueHandle queue, XTaskQueuePort port, uint32_t delay,
                              void* context, XTaskQueueCallback* callback) noexcept
{
    SAKE_TRACE("%p port %u delay %u", queue, static_cast<unsigned>(port), delay);
    if (queue == nullptr)
        return E_GAMERUNTIME_INVALID_HANDLE;
    return ::XTaskQueueSubmitDelayedCallback(queue, port, delay, context, callback);
}

HRESULT RegisterWaiter(void*, XTaskQueueHandle queue, XTaskQueuePort port, HANDLE wait, void* context,
                       XTaskQueueCallback* callback, XTaskQueueRegistrationToken* token) noexcept
{
    SAKE_TRACE("%p port %u", queue, static_cast<unsigned>(port));
    if (queue == nullptr)
        return E_GAMERUNTIME_INVALID_HANDLE;
    return ::XTaskQueueRegisterWaiter(queue, port, wait, context, callback, token);
}

void UnregisterWaiter(void*, XTaskQueueHandle queue, XTaskQueueRegistrationToken token) noexcept
{
    SAKE_TRACE("%p %llu", queue, static_cast<unsigned long long>(token.token));
    if (queue != nullptr)
        ::XTaskQueueUnregisterWaiter(queue, token);
}

HRESULT Terminate(void*, XTaskQueueHandle queue, bool wait, void* context,
                  XTaskQueueTerminatedCallback* callback) noexcept
{
    SAKE_TRACE("%p wait %d", queue, wait);
    if (queue == nullptr)
        return E_GAMERUNTIME_INVALID_HANDLE;
    return ::XTaskQueueTerminate(queue, wait, context, callback);
}

HRESULT RegisterMonitor(void*, XTaskQueueHandle queue, void* context, XTaskQueueMonitorCallback* callback,
                        XTaskQueueRegistrationToken* token) noexcept
{
    SAKE_TRACE("%p", queue);
    if (queue == nullptr)
        return E_GAMERUNTIME_INVALID_HANDLE;
    return ::XTaskQueueRegisterMonitor(queue, context, callback, token);
}

void UnregisterMonitor(void*, XTaskQueueHandle queue, XTaskQueueRegistrationToken token) noexcept
{
    SAKE_TRACE("%p %llu", queue, static_cast<unsigned long long>(token.token));
    if (queue != nullptr)
        ::XTaskQueueUnregisterMonitor(queue, token);
}

bool GetCurrentProcessTaskQueue(void*, XTaskQueueHandle* queue) noexcept
{
    SAKE_TRACE("");
    return ::XTaskQueueGetCurrentProcessTaskQueue(queue);
}

void SetCurrentProcessTaskQueue(void*, XTaskQueueHandle queue) noexcept
{
    SAKE_TRACE("%p", queue);
    ::XTaskQueueSetCurrentProcessTaskQueue(queue);
}

HRESULT SetTimeSensitive(void*, bool timeSensitive) noexcept
{
    SAKE_TRACE("%d", timeSensitive);
    t_timeSensitive = timeSensitive;
    return S_OK;
}

HRESULT Slot25(void*) noexcept
{
    SAKE_TRACE("unknown slot 25");
    return S_OK;
}

void AssertNotTimeSensitive(void*) noexcept
{
    if (t_timeSensitive)
        SAKE_TRACE("called on a time-sensitive thread");
}

bool IsTimeSensitive(void*) noexcept
{
    return t_timeSensitive;
}

constexpr XThreadingVtbl kVtbl = {
    .unknown = kUnknown,
    .XAsyncGetStatus = GetStatus,
    .XAsyncGetResultSize = GetResultSize,
    .XAsyncCancel = Cancel,
    .XAsyncRun = Run,
    .XAsyncBegin = Begin,
    .Slot5 = Slot5,
    .XAsyncSchedule = Schedule,
    .XAsyncComplete = Complete,
    .XAsyncGetResult = GetResult,
    .XTaskQueueCreate = Create,
    .XTaskQueueCreateComposite = CreateComposite,
    .XTaskQueueGetPort = GetPort,
    .XTaskQueueDuplicateHandle = DuplicateHandle,
    .XTaskQueueDispatch = Dispatch,
    .XTaskQueueCloseHandle = CloseHandle,
    .XTaskQueueSubmitCallback = SubmitCallback,
    .XTaskQueueSubmitDelayedCallback = SubmitDelayedCallback,
    .XTaskQueueRegisterWaiter = RegisterWaiter,
    .XTaskQueueUnregisterWaiter = UnregisterWaiter,
    .XTaskQueueTerminate = Terminate,
    .XTaskQueueRegisterMonitor = RegisterMonitor,
    .XTaskQueueUnregisterMonitor = UnregisterMonitor,
    .XTaskQueueGetCurrentProcessTaskQueue = GetCurrentProcessTaskQueue,
    .XTaskQueueSetCurrentProcessTaskQueue = SetCurrentProcessTaskQueue,
    .XThreadSetTimeSensitive = SetTimeSensitive,
    .Slot25 = Slot25,
    .XThreadAssertNotTimeSensitive = AssertNotTimeSensitive,
    .XThreadIsTimeSensitive = IsTimeSensitive,
    .beyond = SAKE_BEYOND(28),
};

constexpr GUID kIids[] = {kXThreadingClass};

}  // namespace

const Object kXThreading = {&kVtbl, "XThreading", kIids, std::size(kIids)};

}  // namespace sake
