import Foundation

/// Xbox Live's token services: a token for the device, one for the person a Microsoft
/// sign-in names, and from those an XSTS token for each relying party a title calls.
///
/// Which request shapes came from Microsoft's documentation and which from the services'
/// own answers is in docs/gdk.md.
public struct XboxLiveAuth: Sendable {
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    /// What a sake bottle reports itself as in `system.reg`, since the title the tokens are
    /// for runs there.
    public static let windowsVersion = "10.0.19045"

    public init(transport: HTTPTransport = .ephemeral(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func deviceToken(key: ProofKey, deviceID: UUID) async throws -> XboxToken {
        try await token(
            from: URL(string: "https://device.auth.xboxlive.com/device/authenticate")!,
            body: [
                "RelyingParty": "http://auth.xboxlive.com",
                "TokenType": "JWT",
                "Properties": [
                    "AuthMethod": "ProofOfPossession",
                    "Id": "{\(deviceID.uuidString)}",
                    "DeviceType": "Win32",
                    "Version": Self.windowsVersion,
                    "ProofKey": key.jwk,
                ],
            ],
            key: key
        )
    }

    /// For a login.live.com access token, whose ticket goes as `t=`; an Entra token would go
    /// as `d=`. With no `key` the request is neither signed nor bound to one.
    public func userToken(accessToken: String, key: ProofKey?) async throws -> XboxToken {
        var properties: [String: Any] = [
            "AuthMethod": "RPS",
            "SiteName": "user.auth.xboxlive.com",
            "RpsTicket": "t=\(accessToken)",
        ]
        if let key { properties["ProofKey"] = key.jwk }
        return try await token(
            from: URL(string: "https://user.auth.xboxlive.com/user/authenticate")!,
            body: ["RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT", "Properties": properties],
            key: key
        )
    }

    /// `relyingParty` exactly as the endpoint table spells it: a custom one keeps its
    /// trailing slash.
    public func xstsToken(
        relyingParty: String,
        userToken: XboxToken,
        deviceToken: XboxToken? = nil,
        titleToken: XboxToken? = nil,
        key: ProofKey?
    ) async throws -> XboxToken {
        var properties: [String: Any] = ["SandboxId": "RETAIL", "UserTokens": [userToken.token]]
        if let deviceToken { properties["DeviceToken"] = deviceToken.token }
        if let titleToken { properties["TitleToken"] = titleToken.token }
        return try await token(
            from: URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!,
            body: ["RelyingParty": relyingParty, "TokenType": "JWT", "Properties": properties],
            key: key
        )
    }

    private func token(from url: URL, body: [String: Any], key: ProofKey?) async throws -> XboxToken {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-xbl-contract-version")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        if let key {
            request.setValue(try key.signature(for: request, at: now()), forHTTPHeaderField: "Signature")
        }

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw XboxLiveError(status: response.statusCode, answer: data)
        }
        guard let token = XboxToken(answer: data) else {
            throw XboxLiveError.unreadable(status: response.statusCode)
        }
        return token
    }
}

public struct XboxToken: Sendable, Equatable, Codable {
    public let token: String
    public let issued: Date
    public let notAfter: Date
    /// Only in a user's tokens, and a relying party other than `http://xboxlive.com` may
    /// carry the user hash alone.
    public let user: XboxUser?

    init?(answer data: Data) {
        struct Answer: Decodable {
            let IssueInstant: String
            let NotAfter: String
            let Token: String
            let DisplayClaims: Claims?
        }
        struct Claims: Decodable {
            let xui: [XboxUser]?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let issued = Self.date(answer.IssueInstant),
              let notAfter = Self.date(answer.NotAfter)
        else { return nil }
        token = answer.Token
        self.issued = issued
        self.notAfter = notAfter
        user = answer.DisplayClaims?.xui?.first
    }

    /// Xbox Live writes seven fractional digits, and some answers none.
    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

public struct XboxUser: Sendable, Equatable, Codable {
    /// What an `Authorization: XBL3.0 x=<hash>;<token>` header names the user by.
    public let userHash: String
    public let xuid: String?
    public let gamertag: String?
    public let ageGroup: String?
    public let privileges: String?

    enum CodingKeys: String, CodingKey {
        case userHash = "uhs"
        case xuid = "xid"
        case gamertag = "gtg"
        case ageGroup = "agg"
        case privileges = "prv"
    }
}

public enum XboxLiveError: Error, Equatable, LocalizedError {
    case refused(status: Int, xerr: UInt32?, redirect: URL?)
    case unreadable(status: Int)
    case anonymous

    init(status: Int, answer data: Data) {
        struct Answer: Decodable {
            let XErr: UInt32?
            let Redirect: String?
        }
        let answer = try? JSONDecoder().decode(Answer.self, from: data)
        self = .refused(status: status, xerr: answer?.XErr, redirect: answer?.Redirect.flatMap(URL.init(string:)))
    }

    /// Microsoft's names for what is wrong with an account, from "Title service calls to Xbox
    /// services", which says to send the person to xbox.com for every one of them.
    static let accountIssues: [UInt32: String] = [
        0x8015_DC03: "Enforcement Ban",
        0x8015_DC05: "Parental Restriction",
        0x8015_DC09: "Account Creation Required",
        0x8015_DC0A: "Terms of Use not Accepted",
        0x8015_DC0B: "Country/region not Authorized",
        0x8015_DC0C: "Age Verification Required",
        0x8015_DC0D: "Account Curfew",
        0x8015_DC0E: "Child not in Family",
        0x8015_DC0F: "CSV Transition Required",
        0x8015_DC10: "Account Maintenance Required",
        0x8015_DC13: "Gamertag Change Required",
    ]

    public var errorDescription: String? {
        switch self {
        case .refused(_, let xerr?, _) where Self.accountIssues[xerr] != nil:
            "There is an issue with this Xbox account (\(Self.accountIssues[xerr]!)). Sign in at xbox.com to resolve it."
        case .refused(_, let xerr?, _) where xerr == 0x8015_DC31 || xerr == 0x8015_DC32:
            "Xbox Live's sign-in is having an outage"
        case .refused(let status, let xerr?, _):
            "Xbox Live refused the sign-in with HTTP \(status), XErr \(String(format: "0x%08X", xerr))"
        case .refused(let status, nil, _):
            "Xbox Live refused the sign-in with HTTP \(status)"
        case .unreadable(let status):
            "Xbox Live answered HTTP \(status) with something that is not a token"
        case .anonymous:
            "Xbox Live signed the account in without saying who it is"
        }
    }
}
