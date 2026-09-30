#include "runtime.h"

#include <cstdarg>

namespace sake {
namespace {

INIT_ONCE g_logOnce = INIT_ONCE_STATIC_INIT;
HANDLE g_log = INVALID_HANDLE_VALUE;
char g_exe[64] = "?";

BOOL CALLBACK OpenLog(PINIT_ONCE, void*, void**) noexcept
{
    wchar_t path[MAX_PATH];
    DWORD length = GetTempPathW(MAX_PATH, path);
    if (length == 0 || length + 20 >= MAX_PATH)
        return TRUE;
    wcscat_s(path, L"xgameruntime.log");

    // Two processes of the same title write here at once, and a crash with the crash
    // dialog turned off ends a process without flushing anything: append-only, shared,
    // one unbuffered write per line.
    g_log = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

    char exe[MAX_PATH];
    if (GetModuleFileNameA(nullptr, exe, MAX_PATH) != 0) {
        const char* name = strrchr(exe, '\\');
        strncpy_s(g_exe, name ? name + 1 : exe, _TRUNCATE);
    }
    return TRUE;
}

}  // namespace

void Log(const char* format, ...) noexcept
{
    InitOnceExecuteOnce(&g_logOnce, OpenLog, nullptr, nullptr);
    if (g_log == INVALID_HANDLE_VALUE)
        return;

    char line[1024];
    SYSTEMTIME now;
    GetLocalTime(&now);
    int length = snprintf(line, sizeof(line), "%04u-%02u-%02u %02u:%02u:%02u.%03u [%lu %s] ",
                          now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
                          now.wMilliseconds, GetCurrentProcessId(), g_exe);
    if (length < 0)
        return;

    va_list args;
    va_start(args, format);
    int message = vsnprintf(line + length, sizeof(line) - length - 1, format, args);
    va_end(args);
    if (message < 0)
        message = 0;
    length = std::min<int>(length + message, sizeof(line) - 2);
    line[length++] = '\n';

    DWORD written;
    WriteFile(g_log, line, static_cast<DWORD>(length), &written, nullptr);
}

void FormatGuid(const GUID& guid, char (&out)[40]) noexcept
{
    snprintf(out, sizeof(out), "%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             static_cast<unsigned long>(guid.Data1), guid.Data2, guid.Data3, guid.Data4[0],
             guid.Data4[1], guid.Data4[2], guid.Data4[3], guid.Data4[4], guid.Data4[5],
             guid.Data4[6], guid.Data4[7]);
}

}  // namespace sake

void SakeLogFailure(const char* what, const char* file, int line) noexcept
{
    const char* name = strrchr(file, '/');
    sake::Log("libHttpClient %s at %s:%d", what, name ? name + 1 : file, line);
}
