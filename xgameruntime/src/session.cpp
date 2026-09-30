#include "mailbox.h"

#include <cstdlib>

namespace sake {
namespace {

struct TokenData {
    size_t tokenSize;
    size_t signatureSize;
    const char* token;
    const char* signature;
};

struct TokenDataUtf16 {
    size_t tokenCount;
    size_t signatureCount;
    const wchar_t* token;
    const wchar_t* signature;
};

// "https://83156.playfabapi.com/Client/..." gives "83156.playfabapi.com", lowercased.
std::string HostOf(const char* url) noexcept
{
    std::string host;
    const char* start = url != nullptr ? strstr(url, "://") : nullptr;
    if (start == nullptr)
        return host;
    for (const char* c = start + 3; *c != '\0' && *c != '/' && *c != ':' && *c != '?' && *c != '#'; ++c)
        host += static_cast<char>(tolower(static_cast<unsigned char>(*c)));
    return host;
}

bool Covers(const std::string& endpoint, const std::string& host) noexcept
{
    if (host == endpoint)
        return true;
    return host.size() > endpoint.size() && host.compare(host.size() - endpoint.size(), endpoint.size(), endpoint) == 0 &&
           host[host.size() - endpoint.size() - 1] == '.';
}

size_t Utf16Length(const std::string& text) noexcept
{
    int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
    return length > 0 ? static_cast<size_t>(length) : 1;
}

}  // namespace

uint64_t Now() noexcept
{
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    uint64_t ticks = (static_cast<uint64_t>(now.dwHighDateTime) << 32) | now.dwLowDateTime;
    return ticks / 10'000'000 - 11'644'473'600ULL;
}

const Session::Token* Session::Named(const char* relyingParty) const noexcept
{
    for (const Token& token : tokens) {
        if (token.relyingParty == relyingParty)
            return &token;
    }
    return nullptr;
}

// The longest endpoint that covers the host wins, the way a table lookup would.
const Session::Token* Session::TokenFor(const char* url, bool* covered) const noexcept
{
    std::string host = HostOf(url);
    const Endpoint* best = nullptr;
    for (const Endpoint& endpoint : endpoints) {
        if (Covers(endpoint.host, host) && (best == nullptr || endpoint.host.size() > best->host.size()))
            best = &endpoint;
    }
    if (covered != nullptr)
        *covered = best != nullptr;
    return best != nullptr ? Named(best->relyingParty.c_str()) : nullptr;
}

bool ReadSession(Session& session) noexcept
{
    wchar_t folder[MAX_PATH];
    if (!MailboxFolder(folder))
        return false;
    std::vector<char> text(65536);
    Session read;
    bool ok = ReadFields(folder, L"session", text.data(), text.size(), [&](const char* key, const char* value) {
        if (strcmp(key, "xuid") == 0) {
            read.xuid = strtoull(value, nullptr, 10);
        } else if (strcmp(key, "gamertag") == 0) {
            read.gamertag = value;
        } else if (strcmp(key, "user-hash") == 0) {
            read.userHash = value;
        } else if (strcmp(key, "age-group") == 0) {
            read.ageGroup = value;
        } else if (strcmp(key, "privileges") == 0) {
            read.privileges = value;
        } else if (strcmp(key, "token") == 0) {
            // <relying party> <expiry> <token>
            const char* expiry = strchr(value, ' ');
            const char* token = expiry != nullptr ? strchr(expiry + 1, ' ') : nullptr;
            if (token != nullptr)
                read.tokens.push_back({std::string(value, expiry), strtoull(expiry + 1, nullptr, 10), token + 1});
        } else if (strcmp(key, "endpoint") == 0) {
            const char* space = strchr(value, ' ');
            if (space != nullptr)
                read.endpoints.push_back({std::string(value, space), space + 1});
        }
    });
    // One written before sake said which host takes which token cannot answer a request.
    if (!ok || read.xuid == 0 || read.userHash.empty() || read.endpoints.empty())
        return false;
    session = std::move(read);
    return true;
}

size_t Payload::Size() const noexcept
{
    switch (kind) {
    case Kind::User:
        return sizeof(XUserHandle);
    case Kind::Token:
        return sizeof(TokenData) + token.size() + 1;
    case Kind::TokenUtf16:
        return sizeof(TokenDataUtf16) + Utf16Length(token) * sizeof(wchar_t);
    default:
        return 0;
    }
}

// Into the title's own buffer, so the pointers point into it. No signature: every token
// sake mints for a title is sent unsigned (docs/gdk.md).
void Payload::Write(void* buffer) const noexcept
{
    switch (kind) {
    case Kind::User:
        memcpy(buffer, &user, sizeof(user));
        break;
    case Kind::Token: {
        auto* data = static_cast<TokenData*>(buffer);
        char* text = reinterpret_cast<char*>(data + 1);
        memcpy(text, token.c_str(), token.size() + 1);
        *data = {token.size() + 1, 0, text, nullptr};
        break;
    }
    case Kind::TokenUtf16: {
        auto* data = static_cast<TokenDataUtf16*>(buffer);
        wchar_t* text = reinterpret_cast<wchar_t*>(data + 1);
        size_t length = Utf16Length(token);
        if (MultiByteToWideChar(CP_UTF8, 0, token.c_str(), -1, text, static_cast<int>(length)) == 0)
            text[0] = L'\0';
        *data = {length * sizeof(wchar_t), 0, text, nullptr};
        break;
    }
    default:
        break;
    }
}

}  // namespace sake
