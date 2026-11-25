#include "runtime.h"
#include "guids.h"
#include "mailbox.h"

#include <string>
#include <utility>

namespace sake {
namespace {

// Errors from Microsoft's XGameSave reference, read 2026-11-26.
constexpr HRESULT E_GS_INVALID_CONTAINER_NAME = static_cast<HRESULT>(0x80830001);
constexpr HRESULT E_GS_UPDATE_TOO_BIG = static_cast<HRESULT>(0x80830005);
constexpr HRESULT E_GS_PROVIDED_BUFFER_TOO_SMALL = static_cast<HRESULT>(0x80830007);
constexpr HRESULT E_GS_BLOB_NOT_FOUND = static_cast<HRESULT>(0x80830008);

constexpr size_t kMaxContainerName = 256;
constexpr size_t kMaxUpdateBytes = 16 * 1024 * 1024;
constexpr int64_t kQuota = 256ll * 1024 * 1024;

// One directory per container and one file per blob, under the title's own folder in the
// bottle. A name is percent-encoded into a file name, so that a '/' in a container name is
// not a directory and no name can reach outside the folder. Nothing a name encodes to starts
// with a dot, which leaves ".name" and ".tmp-" files for this code alone.
struct Provider {
    uint32_t reserved = 0;
};

struct Container {
    std::string name;
    std::wstring directory;
};

struct Update {
    struct Operation {
        bool remove;
        std::string blob;
        std::vector<uint8_t> data;
    };
    std::string container;
    std::wstring directory;
    std::string displayName;
    std::vector<Operation> operations;
};

std::wstring Encode(const char* name) noexcept
{
    std::wstring encoded;
    for (const char* p = name; *p != '\0'; ++p) {
        unsigned char c = static_cast<unsigned char>(*p);
        bool plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
                     c == '-' || (c == '.' && p != name);
        if (plain) {
            encoded.push_back(static_cast<wchar_t>(c));
        } else {
            wchar_t hex[4];
            swprintf(hex, 4, L"%%%02X", c);
            encoded += hex;
        }
    }
    return encoded;
}

std::string Decode(const wchar_t* encoded) noexcept
{
    std::string name;
    for (const wchar_t* p = encoded; *p != L'\0'; ++p) {
        if (*p == L'%' && p[1] != L'\0' && p[2] != L'\0') {
            wchar_t hex[3] = {p[1], p[2], L'\0'};
            name.push_back(static_cast<char>(wcstoul(hex, nullptr, 16)));
            p += 2;
        } else {
            name.push_back(static_cast<char>(*p));
        }
    }
    return name;
}

bool Root(std::wstring& root) noexcept
{
    wchar_t folder[MAX_PATH];
    if (!MailboxFolder(folder))
        return false;
    root = std::wstring(folder) + L"\\GameSave";
    return CreateDirectoryW(root.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS;
}

bool ValidContainerName(const char* name) noexcept
{
    return name != nullptr && name[0] != '\0' && strlen(name) <= kMaxContainerName;
}

bool ReadFile(const std::wstring& path, std::vector<uint8_t>& data) noexcept
{
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    LARGE_INTEGER size{};
    bool ok = GetFileSizeEx(file, &size) && size.QuadPart <= static_cast<LONGLONG>(kMaxUpdateBytes);
    if (ok) {
        data.resize(static_cast<size_t>(size.QuadPart));
        size_t done = 0;
        while (ok && done < data.size()) {
            DWORD read = 0;
            ok = ::ReadFile(file, data.data() + done, static_cast<DWORD>(data.size() - done), &read, nullptr) &&
                 read != 0;
            done += read;
        }
    }
    ::CloseHandle(file);
    return ok;
}

bool WriteFile(const std::wstring& path, const std::vector<uint8_t>& data) noexcept
{
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    bool ok = true;
    size_t done = 0;
    while (ok && done < data.size()) {
        DWORD wrote = 0;
        ok = ::WriteFile(file, data.data() + done, static_cast<DWORD>(data.size() - done), &wrote, nullptr) &&
             wrote != 0;
        done += wrote;
    }
    ok = ok && FlushFileBuffers(file);
    ::CloseHandle(file);
    return ok;
}

int64_t UnixTime(const FILETIME& time) noexcept
{
    uint64_t ticks = (static_cast<uint64_t>(time.dwHighDateTime) << 32) | time.dwLowDateTime;
    return ticks > 116444736000000000ull ? static_cast<int64_t>((ticks - 116444736000000000ull) / 10000000ull) : 0;
}

struct BlobFile {
    std::string name;
    uint32_t size;
    int64_t modified;
};

// The blobs of a container directory, in the order the file system lists them.
std::vector<BlobFile> ListBlobs(const std::wstring& directory) noexcept
{
    std::vector<BlobFile> blobs;
    WIN32_FIND_DATAW found;
    HANDLE find = FindFirstFileW((directory + L"\\*").c_str(), &found);
    if (find == INVALID_HANDLE_VALUE)
        return blobs;
    do {
        if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || found.cFileName[0] == L'.')
            continue;
        blobs.push_back({Decode(found.cFileName), found.nFileSizeLow, UnixTime(found.ftLastWriteTime)});
    } while (FindNextFileW(find, &found));
    FindClose(find);
    return blobs;
}

std::string DisplayName(const std::wstring& directory) noexcept
{
    std::vector<uint8_t> text;
    if (!ReadFile(directory + L"\\.name", text))
        return {};
    return std::string(text.begin(), text.end());
}

bool ContainerDirectory(const char* name, std::wstring& directory) noexcept
{
    std::wstring root;
    if (!Root(root))
        return false;
    directory = root + L"\\" + Encode(name);
    return true;
}

using BlobCallback = bool (*)(const XGameSaveBlobInfo*, void*) noexcept;
using ContainerCallback = bool (*)(const XGameSaveContainerInfo*, void*) noexcept;

const char kProviderIdentity = 0;
const char kQuotaIdentity = 0;
const char kDeleteIdentity = 0;
const char kReadIdentity = 0;
const char kSubmitIdentity = 0;

HRESULT InitializeProvider(void*, XUserHandle, const char* configurationId, bool syncOnDemand,
                           Provider** provider) noexcept
{
    SAKE_TRACE("config %s syncOnDemand %d", configurationId ? configurationId : "", syncOnDemand);
    if (provider == nullptr)
        return E_POINTER;
    *provider = new (std::nothrow) Provider;
    return *provider != nullptr ? S_OK : E_OUTOFMEMORY;
}

HRESULT InitializeProviderAsync(void*, XUserHandle, const char* configurationId, bool syncOnDemand,
                                XAsyncBlock* async) noexcept
{
    SAKE_TRACE("config %s syncOnDemand %d", configurationId ? configurationId : "", syncOnDemand);
    Provider* provider = new (std::nothrow) Provider;
    if (provider == nullptr)
        return E_OUTOFMEMORY;
    Payload payload;
    payload.kind = Payload::Kind::Value;
    payload.value = reinterpret_cast<uint64_t>(provider);
    return CompleteNow(async, &kProviderIdentity, "XGameSaveInitializeProviderAsync", S_OK, std::move(payload));
}

HRESULT InitializeProviderResult(void*, XAsyncBlock* async, Provider** provider) noexcept
{
    if (provider != nullptr)
        *provider = nullptr;
    return ::XAsyncGetResult(async, &kProviderIdentity, sizeof(Provider*), provider, nullptr);
}

void CloseProvider(void*, Provider* provider) noexcept
{
    SAKE_TRACE("%p", provider);
    delete provider;
}

HRESULT GetRemainingQuota(void*, Provider*, int64_t* remaining) noexcept
{
    if (remaining == nullptr)
        return E_POINTER;
    *remaining = kQuota;
    return S_OK;
}

HRESULT GetRemainingQuotaAsync(void*, Provider*, XAsyncBlock* async) noexcept
{
    Payload payload;
    payload.kind = Payload::Kind::Value;
    payload.value = static_cast<uint64_t>(kQuota);
    return CompleteNow(async, &kQuotaIdentity, "XGameSaveGetRemainingQuotaAsync", S_OK, std::move(payload));
}

HRESULT GetRemainingQuotaResult(void*, XAsyncBlock* async, int64_t* remaining) noexcept
{
    return ::XAsyncGetResult(async, &kQuotaIdentity, sizeof(int64_t), remaining, nullptr);
}

HRESULT RemoveContainer(const char* name) noexcept
{
    std::wstring directory;
    if (!ValidContainerName(name))
        return E_GS_INVALID_CONTAINER_NAME;
    if (!ContainerDirectory(name, directory))
        return E_FAIL;
    for (const BlobFile& blob : ListBlobs(directory))
        DeleteFileW((directory + L"\\" + Encode(blob.name.c_str())).c_str());
    DeleteFileW((directory + L"\\.name").c_str());
    RemoveDirectoryW(directory.c_str());
    return S_OK;
}

HRESULT DeleteContainer(void*, Provider*, const char* name) noexcept
{
    SAKE_TRACE("%s", name ? name : "");
    return RemoveContainer(name);
}

HRESULT DeleteContainerAsync(void*, Provider*, const char* name, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%s", name ? name : "");
    return CompleteNow(async, &kDeleteIdentity, "XGameSaveDeleteContainerAsync", RemoveContainer(name), {});
}

HRESULT DeleteContainerResult(void*, XAsyncBlock* async) noexcept
{
    return ::XAsyncGetResult(async, &kDeleteIdentity, 0, nullptr, nullptr);
}

// Calls `callback` for the container in `directory`, and says whether to go on.
bool Report(const std::string& name, const std::wstring& directory, ContainerCallback callback, void* context) noexcept
{
    std::vector<BlobFile> blobs = ListBlobs(directory);
    std::string display = DisplayName(directory);
    XGameSaveContainerInfo info{};
    info.name = name.c_str();
    info.displayName = display.c_str();
    info.blobCount = static_cast<uint32_t>(blobs.size());
    for (const BlobFile& blob : blobs) {
        info.totalSize += blob.size;
        info.lastModifiedTime = std::max(info.lastModifiedTime, blob.modified);
    }
    return callback(&info, context);
}

HRESULT GetContainerInfo(void*, Provider*, const char* name, void* context, ContainerCallback callback) noexcept
{
    SAKE_TRACE("%s", name ? name : "");
    if (!ValidContainerName(name))
        return E_GS_INVALID_CONTAINER_NAME;
    std::wstring directory;
    if (!ContainerDirectory(name, directory))
        return E_FAIL;
    if (GetFileAttributesW(directory.c_str()) != INVALID_FILE_ATTRIBUTES && callback != nullptr)
        Report(name, directory, callback, context);
    return S_OK;
}

HRESULT EnumerateContainers(const char* prefix, void* context, ContainerCallback callback) noexcept
{
    std::wstring root;
    if (!Root(root))
        return E_FAIL;
    WIN32_FIND_DATAW found;
    HANDLE find = FindFirstFileW((root + L"\\*").c_str(), &found);
    if (find == INVALID_HANDLE_VALUE)
        return S_OK;
    do {
        if (!(found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || found.cFileName[0] == L'.')
            continue;
        std::string name = Decode(found.cFileName);
        if (prefix != nullptr && name.compare(0, strlen(prefix), prefix) != 0)
            continue;
        if (callback != nullptr && !Report(name, root + L"\\" + found.cFileName, callback, context))
            break;
    } while (FindNextFileW(find, &found));
    FindClose(find);
    return S_OK;
}

HRESULT EnumerateContainerInfo(void*, Provider*, void* context, ContainerCallback callback) noexcept
{
    SAKE_TRACE("");
    return EnumerateContainers(nullptr, context, callback);
}

HRESULT EnumerateContainerInfoByName(void*, Provider*, const char* prefix, void* context,
                                     ContainerCallback callback) noexcept
{
    SAKE_TRACE("%s", prefix ? prefix : "");
    return EnumerateContainers(prefix, context, callback);
}

HRESULT CreateContainer(void*, Provider*, const char* name, Container** container) noexcept
{
    SAKE_TRACE("%s", name ? name : "");
    if (container == nullptr)
        return E_POINTER;
    *container = nullptr;
    if (!ValidContainerName(name))
        return E_GS_INVALID_CONTAINER_NAME;
    std::wstring directory;
    if (!ContainerDirectory(name, directory))
        return E_FAIL;
    *container = new (std::nothrow) Container{name, directory};
    return *container != nullptr ? S_OK : E_OUTOFMEMORY;
}

void CloseContainer(void*, Container* container) noexcept
{
    SAKE_TRACE("%p", container);
    delete container;
}

HRESULT EnumerateBlobs(Container* container, const char* prefix, void* context, BlobCallback callback) noexcept
{
    if (container == nullptr)
        return E_POINTER;
    for (const BlobFile& blob : ListBlobs(container->directory)) {
        if (prefix != nullptr && blob.name.compare(0, strlen(prefix), prefix) != 0)
            continue;
        XGameSaveBlobInfo info{blob.name.c_str(), blob.size};
        if (callback != nullptr && !callback(&info, context))
            break;
    }
    return S_OK;
}

HRESULT EnumerateBlobInfo(void*, Container* container, void* context, BlobCallback callback) noexcept
{
    SAKE_TRACE("%s", container ? container->name.c_str() : "");
    return EnumerateBlobs(container, nullptr, context, callback);
}

HRESULT EnumerateBlobInfoByName(void*, Container* container, const char* prefix, void* context,
                                BlobCallback callback) noexcept
{
    SAKE_TRACE("%s %s", container ? container->name.c_str() : "", prefix ? prefix : "");
    return EnumerateBlobs(container, prefix, context, callback);
}

HRESULT LoadBlobs(Container* container, const char** names, uint32_t count, Payload& payload) noexcept
{
    if (container == nullptr || (count != 0 && names == nullptr))
        return E_POINTER;
    payload.kind = Payload::Kind::Blobs;
    for (uint32_t i = 0; i < count; ++i) {
        std::vector<uint8_t> data;
        if (names[i] == nullptr || !ReadFile(container->directory + L"\\" + Encode(names[i]), data))
            return E_GS_BLOB_NOT_FOUND;
        payload.blobs.emplace_back(names[i], std::move(data));
    }
    return S_OK;
}

HRESULT ReadBlobData(void*, Container* container, const char** names, uint32_t* count, size_t size,
                     XGameSaveBlob* blobs) noexcept
{
    SAKE_TRACE("%s", container ? container->name.c_str() : "");
    if (count == nullptr)
        return E_POINTER;
    Payload payload;
    HRESULT hr = LoadBlobs(container, names, *count, payload);
    if (FAILED(hr))
        return hr;
    if (blobs == nullptr || size < payload.Size())
        return E_GS_PROVIDED_BUFFER_TOO_SMALL;
    payload.Write(blobs);
    *count = static_cast<uint32_t>(payload.blobs.size());
    return S_OK;
}

HRESULT ReadBlobDataAsync(void*, Container* container, const char** names, uint32_t count,
                          XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%s %u blobs", container ? container->name.c_str() : "", count);
    Payload payload;
    HRESULT hr = LoadBlobs(container, names, count, payload);
    if (FAILED(hr))
        payload = {};
    return CompleteNow(async, &kReadIdentity, "XGameSaveReadBlobDataAsync", hr, std::move(payload));
}

HRESULT ReadBlobDataResult(void*, XAsyncBlock* async, size_t size, XGameSaveBlob* blobs, uint32_t* count) noexcept
{
    if (count != nullptr)
        *count = 0;
    size_t used = 0;
    HRESULT hr = ::XAsyncGetResult(async, &kReadIdentity, size, blobs, &used);
    if (SUCCEEDED(hr) && count != nullptr && used >= sizeof(uint32_t))
        memcpy(count, reinterpret_cast<const char*>(blobs) + used - sizeof(uint32_t), sizeof(uint32_t));
    SAKE_TRACE("-> %#lx, %u blobs", static_cast<unsigned long>(hr), count ? *count : 0);
    return hr;
}

HRESULT CreateUpdate(void*, Container* container, const char* displayName, Update** update) noexcept
{
    SAKE_TRACE("%s", container ? container->name.c_str() : "");
    if (container == nullptr || update == nullptr)
        return E_POINTER;
    *update = new (std::nothrow) Update{container->name, container->directory, displayName ? displayName : "", {}};
    return *update != nullptr ? S_OK : E_OUTOFMEMORY;
}

void CloseUpdate(void*, Update* update) noexcept
{
    SAKE_TRACE("%p", update);
    delete update;
}

HRESULT SubmitBlobWrite(void*, Update* update, const char* blob, const uint8_t* data, size_t size) noexcept
{
    SAKE_TRACE("%s %zu bytes", blob ? blob : "", size);
    if (update == nullptr || blob == nullptr || (size != 0 && data == nullptr))
        return E_POINTER;
    update->operations.push_back({false, blob, std::vector<uint8_t>(data, data + size)});
    return S_OK;
}

HRESULT SubmitBlobDelete(void*, Update* update, const char* blob) noexcept
{
    SAKE_TRACE("%s", blob ? blob : "");
    if (update == nullptr || blob == nullptr)
        return E_POINTER;
    update->operations.push_back({true, blob, {}});
    return S_OK;
}

// Every write goes to a temporary file first, and only when they all have does a file
// replace the one it is an update of, so that a failure part way leaves the blobs as they were.
HRESULT Apply(Update* update) noexcept
{
    if (update == nullptr)
        return E_POINTER;
    size_t total = 0;
    for (const auto& operation : update->operations)
        total += operation.data.size();
    if (total > kMaxUpdateBytes)
        return E_GS_UPDATE_TOO_BIG;

    std::wstring root;
    if (!Root(root))
        return E_FAIL;
    if (!CreateDirectoryW(update->directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS)
        return E_FAIL;

    std::vector<std::pair<std::wstring, std::wstring>> staged;
    auto discard = [&] {
        for (const auto& file : staged)
            DeleteFileW(file.first.c_str());
    };
    for (const auto& operation : update->operations) {
        if (operation.remove)
            continue;
        std::wstring name = Encode(operation.blob.c_str());
        std::wstring temporary = update->directory + L"\\.tmp-" + name;
        if (!WriteFile(temporary, operation.data)) {
            discard();
            return HRESULT_FROM_WIN32(GetLastError() != 0 ? GetLastError() : ERROR_WRITE_FAULT);
        }
        staged.emplace_back(temporary, update->directory + L"\\" + name);
    }
    for (const auto& file : staged) {
        if (!MoveFileExW(file.first.c_str(), file.second.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            DWORD error = GetLastError();
            discard();
            return HRESULT_FROM_WIN32(error);
        }
    }
    for (const auto& operation : update->operations) {
        if (operation.remove)
            DeleteFileW((update->directory + L"\\" + Encode(operation.blob.c_str())).c_str());
    }
    if (!update->displayName.empty()) {
        std::vector<uint8_t> text(update->displayName.begin(), update->displayName.end());
        WriteFile(update->directory + L"\\.name", text);
    }
    Log("game save: %s updated, %zu operations", update->container.c_str(), update->operations.size());
    return S_OK;
}

HRESULT SubmitUpdate(void*, Update* update) noexcept
{
    SAKE_TRACE("%p", update);
    return Apply(update);
}

HRESULT SubmitUpdateAsync(void*, Update* update, XAsyncBlock* async) noexcept
{
    SAKE_TRACE("%p", update);
    return CompleteNow(async, &kSubmitIdentity, "XGameSaveSubmitUpdateAsync", Apply(update), {});
}

HRESULT SubmitUpdateResult(void*, XAsyncBlock* async) noexcept
{
    return ::XAsyncGetResult(async, &kSubmitIdentity, 0, nullptr, nullptr);
}

// XGameSaveFiles is another way of saving that this runtime does not offer.
HRESULT Unanswered(void*) noexcept
{
    SAKE_TRACE("not implemented");
    return E_NOTIMPL;
}

using Slot = HRESULT (*)(void*) noexcept;
constexpr size_t kFirstSlot = 3;
constexpr size_t kSlots = 30;  // 3 .. 32

struct XGameSaveVtbl {
    Unknown unknown;
    Slot slots[kSlots];
    BeyondSlots beyond;
};

// The numbers are the offsets the title's thunks call at, divided by 8 (docs/gdk.md).
template <typename Function>
void Place(XGameSaveVtbl& vtbl, size_t slot, Function function) noexcept
{
    vtbl.slots[slot - kFirstSlot] = reinterpret_cast<Slot>(function);
}

XGameSaveVtbl MakeVtbl() noexcept
{
    XGameSaveVtbl vtbl = {kUnknown, {}, SAKE_BEYOND(33)};
    for (Slot& slot : vtbl.slots)
        slot = Unanswered;
    Place(vtbl, 3, InitializeProvider);
    Place(vtbl, 4, InitializeProviderAsync);
    Place(vtbl, 5, InitializeProviderResult);
    Place(vtbl, 6, CloseProvider);
    Place(vtbl, 7, GetRemainingQuota);
    Place(vtbl, 8, GetRemainingQuotaAsync);
    Place(vtbl, 9, GetRemainingQuotaResult);
    Place(vtbl, 10, DeleteContainer);
    Place(vtbl, 11, DeleteContainerAsync);
    Place(vtbl, 12, DeleteContainerResult);
    Place(vtbl, 13, GetContainerInfo);
    Place(vtbl, 14, EnumerateContainerInfo);
    Place(vtbl, 15, EnumerateContainerInfoByName);
    Place(vtbl, 16, CreateContainer);
    Place(vtbl, 17, CloseContainer);
    Place(vtbl, 18, EnumerateBlobInfo);
    Place(vtbl, 19, EnumerateBlobInfoByName);
    Place(vtbl, 20, ReadBlobData);
    Place(vtbl, 21, ReadBlobDataAsync);
    Place(vtbl, 22, ReadBlobDataResult);
    Place(vtbl, 23, CreateUpdate);
    Place(vtbl, 24, CloseUpdate);
    Place(vtbl, 25, SubmitBlobWrite);
    Place(vtbl, 26, SubmitBlobDelete);
    Place(vtbl, 27, SubmitUpdate);
    Place(vtbl, 28, SubmitUpdateAsync);
    Place(vtbl, 29, SubmitUpdateResult);
    return vtbl;
}

const XGameSaveVtbl kVtbl = MakeVtbl();
constexpr GUID kIids[] = {kXGameSaveClass, kXGameSaveIid};

}  // namespace

const Object kXGameSave = {&kVtbl, "XGameSave", kIids, std::size(kIids)};

}  // namespace sake
