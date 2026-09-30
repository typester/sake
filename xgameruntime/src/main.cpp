#include "runtime.h"
#include "guids.h"

namespace sake {

HRESULT ObjectQueryInterface(void* self, const GUID* iid, void** out) noexcept
{
    if (out == nullptr)
        return E_POINTER;
    if (iid != nullptr && (IsEqualGUID(*iid, kIUnknownIid) || Answers(*static_cast<Object*>(self), *iid))) {
        *out = self;
        return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
}

ULONG ObjectAddRef(void*) noexcept
{
    return 2;
}

ULONG ObjectRelease(void*) noexcept
{
    return 1;
}

bool Answers(const Object& object, const GUID& iid) noexcept
{
    for (size_t i = 0; i < object.iidCount; ++i) {
        if (IsEqualGUID(object.iids[i], iid))
            return true;
    }
    return false;
}

XTaskQueueRegistrationToken NextToken() noexcept
{
    static std::atomic<uint64_t> next{1};
    return {next++};
}

namespace {

struct Class {
    const GUID& clsid;
    const Object* objects[2];
    std::atomic<uint32_t> answered[2][8];
};

Class g_classes[] = {
    {kXThreadingClass, {&kXThreading}, {}},
    {kXGameRuntimeFeatureClass, {&kXGameRuntimeFeature}, {}},
    {kXErrorClass, {&kXError}, {}},
    {kXSystemClass, {&kXSystem}, {}},
    {kXSystemAnalyticsClass, {&kXSystemAnalytics}, {}},
    {kXNetworkingClass, {&kXNetworking}, {}},
    {kXUserClass, {&kXUser, &kXUserGamertag}, {}},
    {kXUserDeviceClass, {&kXUserDevice}, {}},
    {kXGameClass, {&kXGame}, {}},
    {kRegistration0651aae2Class, {&kRegistration0651aae2}, {}},
    {kRegistration95fd18d2Class, {&kRegistration95fd18d2}, {}},
};

struct Refused {
    GUID clsid;
    GUID iid;
    uint32_t count;
};

SRWLOCK g_refusedLock = SRWLOCK_INIT;
Refused g_refused[64];
size_t g_refusedCount;

void LogRefused(const GUID& clsid, const GUID& iid, bool knownClass) noexcept
{
    uint32_t count = 0;
    AcquireSRWLockExclusive(&g_refusedLock);
    for (size_t i = 0; i < g_refusedCount; ++i) {
        if (IsEqualGUID(g_refused[i].clsid, clsid) && IsEqualGUID(g_refused[i].iid, iid)) {
            count = ++g_refused[i].count;
            break;
        }
    }
    if (count == 0 && g_refusedCount < std::size(g_refused)) {
        g_refused[g_refusedCount++] = {clsid, iid, 1};
        count = 1;
    }
    ReleaseSRWLockExclusive(&g_refusedLock);

    if (count == 0 || count <= 20 || (count & (count - 1)) == 0) {
        char c[40], i[40];
        FormatGuid(clsid, c);
        FormatGuid(iid, i);
        Log("QueryApiImpl #%u refused class %s iid %s (%s)", count, c, i,
            knownClass ? "a version this runtime does not answer" : "a class this runtime does not have");
    }
}

void Initialized(const char* how, uint64_t gdkVersion, uint64_t gsVersion, uint64_t flags,
                 const void* options) noexcept
{
    // Thread-pool work, waits and timers are not tied to this module, so it must never be
    // unloaded under them.
    static INIT_ONCE pinned = INIT_ONCE_STATIC_INIT;
    InitOnceExecuteOnce(
        &pinned,
        [](PINIT_ONCE, void*, void**) noexcept -> BOOL {
            HMODULE module;
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                               reinterpret_cast<LPCWSTR>(&NextToken), &module);
            return TRUE;
        },
        nullptr, nullptr);

    SAKE_TRACE("%s gdk %#llx gs %#llx flags %#llx options %p", how,
               static_cast<unsigned long long>(gdkVersion), static_cast<unsigned long long>(gsVersion),
               static_cast<unsigned long long>(flags), options);
}

}  // namespace
}  // namespace sake

using namespace sake;

// SakeKit replaces a copy in a bottle only when it finds this, so a change to it leaves every
// copy already placed where it is for good.
extern "C" __attribute__((used)) const char kSakeRuntime[] = "sake's own xgameruntime.dll";

extern "C" BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void*) noexcept
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        wchar_t path[MAX_PATH];
        if (GetModuleFileNameW(instance, path, MAX_PATH) == 0)
            path[0] = L'\0';
        Log("xgameruntime loaded from %ls", path);
    }
    return TRUE;
}

extern "C" HRESULT InitializeApiImpl(uint32_t gdkVersion, uint32_t gsVersion) noexcept
{
    Initialized("InitializeApiImpl", gdkVersion, gsVersion, 0, nullptr);
    return S_OK;
}

extern "C" HRESULT InitializeApiImplEx(uint64_t gdkVersion, uint64_t gsVersion, uint64_t flags) noexcept
{
    Initialized("InitializeApiImplEx", gdkVersion, gsVersion, flags, nullptr);
    return S_OK;
}

extern "C" HRESULT InitializeApiImplEx2(uint64_t gdkVersion, uint64_t gsVersion, uint64_t flags,
                                        const void* options) noexcept
{
    Initialized("InitializeApiImplEx2", gdkVersion, gsVersion, flags, options);
    return S_OK;
}

// Deliberately not XTaskQueueUninitialize: every module in the process shares the process
// queue, and one module's thunks uninitializing must not close it under the others.
extern "C" HRESULT UninitializeApiImpl() noexcept
{
    SAKE_TRACE("");
    return S_OK;
}

extern "C" void XErrorReport(HRESULT result, const char* message) noexcept
{
    SAKE_TRACE("%#lx %s", static_cast<unsigned long>(result), message ? message : "");
}

extern "C" HRESULT QueryApiImpl(const GUID* clsid, const GUID* iid, void** out) noexcept
{
    if (out == nullptr)
        return E_POINTER;
    *out = nullptr;
    if (clsid == nullptr || iid == nullptr)
        return E_POINTER;

    for (Class& c : g_classes) {
        if (!IsEqualGUID(c.clsid, *clsid))
            continue;
        for (size_t o = 0; o < std::size(c.objects); ++o) {
            const Object* object = c.objects[o];
            if (object == nullptr)
                continue;
            for (size_t i = 0; i < object->iidCount && i < std::size(c.answered[o]); ++i) {
                if (!IsEqualGUID(object->iids[i], *iid))
                    continue;
                uint32_t n = ++c.answered[o][i];
                if (n <= 20 || (n & (n - 1)) == 0) {
                    char text[40];
                    FormatGuid(*iid, text);
                    Log("QueryApiImpl #%u %s iid %s", n, object->name, text);
                }
                *out = const_cast<Object*>(object);
                return S_OK;
            }
        }
        LogRefused(*clsid, *iid, true);
        return E_NOINTERFACE;
    }
    LogRefused(*clsid, *iid, false);
    return E_NOINTERFACE;
}
