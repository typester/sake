// libHttpClient's task sources include "pch.h" first. Their own build supplies one that
// pulls in the whole HTTP client; this supplies only what Source/Task uses.
#pragma once

#include <winsock2.h>
#include <windows.h>
#include <objbase.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <list>
#include <memory>
#include <mutex>
#include <new>
#include <thread>
#include <type_traits>
#include <vector>

#include <httpClient/pal.h>
#include <XTaskQueue.h>
#include <XAsync.h>
#include <XAsyncProvider.h>

void SakeLogFailure(const char* what, const char* file, int line) noexcept;

// libHttpClient's own build maps ASSERT to assert(), which inside a game either takes the
// game down or, with NDEBUG, says nothing. Both are logged here; a fail-fast still fails.
#define ASSERT(x) do { if (!(x)) SakeLogFailure("assertion failed: " #x, __FILE__, __LINE__); } while (0)
#define FAIL_FAST_IF_FAILED(hr) do { HRESULT sake_hr_ = (hr); if (FAILED(sake_hr_)) { SakeLogFailure("fail fast: " #hr, __FILE__, __LINE__); __fastfail(FAST_FAIL_FATAL_APP_EXIT); } } while (0)
#define LOG_IF_FAILED(hr) do { HRESULT sake_hr_ = (hr); if (FAILED(sake_hr_)) SakeLogFailure("failed: " #hr, __FILE__, __LINE__); } while (0)

#define RETURN_HR(hr) return (hr)
#define RETURN_IF_FAILED(hr) do { HRESULT sake_hr_ = (hr); if (FAILED(sake_hr_)) return sake_hr_; } while (0)
#define RETURN_HR_IF(hr, condition) do { if (condition) return (hr); } while (0)
#define RETURN_IF_NULL_ALLOC(p) do { if ((p) == nullptr) return E_OUTOFMEMORY; } while (0)
#define RETURN_LAST_ERROR_IF(condition) do { if (condition) return HRESULT_FROM_WIN32(GetLastError()); } while (0)
#define RETURN_LAST_ERROR_IF_NULL(p) do { if ((p) == nullptr) return HRESULT_FROM_WIN32(GetLastError()); } while (0)
#define CATCH_RETURN() catch (std::bad_alloc const&) { return E_OUTOFMEMORY; } catch (...) { return E_FAIL; }
#define CATCH_RETURN_WITH(errCode) catch (...) { return errCode; }

#define ASYNC_LIB_TRACE(result, message)

// libHttpClient maps this to E_HANDLE because it is not the runtime. Here it is.
#define E_GAMERUNTIME_INVALID_HANDLE ((HRESULT)0x8924010CL)

#ifndef E_ILLEGAL_METHOD_CALL
#define E_ILLEGAL_METHOD_CALL ((HRESULT)0x8000000EL)
#endif

#define SYSTEM_HANDLE_DEFINE_HELPERS(a, b)
#define SystemHandleAssert(h)
#define SystemHandleMarkCreated(h)
#define SystemHandleMarkDestroyed(h)
#define USE_UNIQUE_HANDLES() (true)
#define GetCurrentRuntimeIteration() 0
