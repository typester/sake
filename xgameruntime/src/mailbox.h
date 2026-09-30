// The files a title's runtime and sake talk through, in %LOCALAPPDATA%\Sake\<title ID>.
// docs/gdk.md has what each holds.
#pragma once

#include "runtime.h"

namespace sake {

inline bool PathIn(const wchar_t* folder, const wchar_t* name, wchar_t (&path)[MAX_PATH]) noexcept
{
    return swprintf(path, MAX_PATH, L"%ls\\%ls", folder, name) >= 0;
}

// Made if it is not there.
inline bool MailboxFolder(wchar_t (&folder)[MAX_PATH]) noexcept
{
    uint32_t titleId = TitleId();
    wchar_t base[MAX_PATH];
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
    if (titleId == 0 || length == 0 || length >= MAX_PATH || swprintf(folder, MAX_PATH, L"%ls\\Sake", base) < 0)
        return false;
    CreateDirectoryW(folder, nullptr);
    if (swprintf(folder, MAX_PATH, L"%ls\\Sake\\%08X", base, titleId) < 0)
        return false;
    return CreateDirectoryW(folder, nullptr) || GetLastError() == ERROR_ALREADY_EXISTS;
}

// Calls `each(key, value)` for the lines of a file sake or this runtime wrote, once its
// first line has named the format. `text` is the buffer the file is read into.
template <typename Each>
bool ReadFields(const wchar_t* folder, const wchar_t* name, char* text, size_t size, Each each) noexcept
{
    wchar_t path[MAX_PATH];
    if (!PathIn(folder, name, path))
        return false;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    DWORD read = 0;
    BOOL ok = ReadFile(file, text, static_cast<DWORD>(size - 1), &read, nullptr);
    ::CloseHandle(file);
    if (!ok)
        return false;
    text[read] = '\0';

    bool first = true;
    for (char* line = text; line != nullptr && *line != '\0';) {
        char* next = strchr(line, '\n');
        if (next != nullptr)
            *next++ = '\0';
        size_t length = strlen(line);
        if (length > 0 && line[length - 1] == '\r')
            line[length - 1] = '\0';
        if (first) {
            if (strcmp(line, "sake 1") != 0)
                return false;
            first = false;
        } else if (char* space = strchr(line, ' ')) {
            *space = '\0';
            each(line, space + 1);
        }
        line = next;
    }
    return !first;
}

}  // namespace sake
