import Foundation

/// Microsoft's device-code sign-in on login.live.com (RFC 8628), as the title's own OAuth
/// client: the `MSAAppId` in its `MicrosoftGame.config`, and no other application's.
/// See docs/gdk.md and docs/licensing.md.
public struct MicrosoftSignIn: Sendable {
    public let clientID: String
    private let transport: HTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    public static let scope = "service::user.auth.xboxlive.com::MBI_SSL"
    static let codeURL = URL(string: "https://login.live.com/oauth20_connect.srf")!
    static let tokenURL = URL(string: "https://login.live.com/oauth20_token.srf")!

    /// `sleep` is the throwing `Task.sleep` unless a test says otherwise, which is what
    /// makes cancelling the task stop the polling.
    public init(
        clientID: String,
        transport: HTTPTransport = .ephemeral(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    public struct DeviceCode: Sendable, Equatable {
        /// What the person types into ``verificationURL``.
        public let userCode: String
        public let verificationURL: URL
        /// The page with the code already in it, when the server offers one.
        public let completeVerificationURL: URL?
        public let expiresAt: Date
        let deviceCode: String
        let interval: Duration
    }

    public struct Tokens: Sendable, Equatable, Codable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date
    }

    public func requestCode() async throws -> DeviceCode {
        let (data, _) = try await transport.send(form(Self.codeURL, [
            ("client_id", clientID),
            ("scope", Self.scope),
            ("response_type", "device_code"),
        ]))
        guard let answer = try? JSONDecoder().decode(CodeAnswer.self, from: data),
              let verification = URL(string: answer.verification_uri)
        else { throw MicrosoftSignInError(answer: data) }

        return DeviceCode(
            userCode: answer.user_code,
            verificationURL: verification,
            completeVerificationURL: answer.verification_uri_complete.flatMap(URL.init(string:)),
            expiresAt: now().addingTimeInterval(TimeInterval(answer.expires_in)),
            deviceCode: answer.device_code,
            interval: .seconds(answer.interval ?? 5)
        )
    }

    /// Polls until the person has signed in at the page, turned it down, or let the code run
    /// out.
    public func waitForApproval(of code: DeviceCode) async throws -> Tokens {
        var interval = code.interval
        while true {
            try await sleep(interval)
            guard now() < code.expiresAt else { throw MicrosoftSignInError.expired }

            let (data, _) = try await transport.send(form(Self.tokenURL, [
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("client_id", clientID),
                ("device_code", code.deviceCode),
            ]))
            if let tokens = tokens(from: data, keeping: nil) { return tokens }

            let error = MicrosoftSignInError(answer: data)
            switch error {
            case .pending: continue
            case .slowDown: interval += .seconds(5)
            default: throw error
            }
        }
    }

    /// A new access token for an old refresh token. The server may or may not hand back a
    /// new refresh token as well; when it does not, the old one is still the one to keep.
    public func refresh(_ refreshToken: String) async throws -> Tokens {
        let (data, _) = try await transport.send(form(Self.tokenURL, [
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("scope", Self.scope),
            ("refresh_token", refreshToken),
        ]))
        guard let tokens = tokens(from: data, keeping: refreshToken) else {
            throw MicrosoftSignInError(answer: data)
        }
        return tokens
    }

    private func tokens(from data: Data, keeping refreshToken: String?) -> Tokens? {
        guard let answer = try? JSONDecoder().decode(TokenAnswer.self, from: data),
              let access = answer.access_token,
              let refresh = answer.refresh_token ?? refreshToken
        else { return nil }
        return Tokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now().addingTimeInterval(TimeInterval(answer.expires_in ?? 3600))
        )
    }

    private func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formBody(fields).utf8)
        return request
    }

    /// RFC 3986's unreserved characters and nothing else. `URLComponents` would leave a `+`
    /// as it is, and a form's reader takes that for a space.
    static func formBody(_ fields: [(String, String)]) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return fields.map { name, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(name)=\(encoded)"
        }.joined(separator: "&")
    }

    private struct CodeAnswer: Decodable {
        let user_code: String
        let device_code: String
        let verification_uri: String
        let verification_uri_complete: String?
        let interval: Int?
        let expires_in: Int
    }

    private struct TokenAnswer: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
    }
}

public enum MicrosoftSignInError: Error, Equatable, LocalizedError {
    case pending
    case slowDown
    case declined
    case expired
    case refused(String)
    case unreadable

    init(answer data: Data) {
        struct Answer: Decodable {
            let error: String
            let error_description: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            self = .unreadable
            return
        }
        switch answer.error {
        case "authorization_pending": self = .pending
        case "slow_down": self = .slowDown
        case "authorization_declined", "access_denied": self = .declined
        case "expired_token": self = .expired
        default: self = .refused(answer.error_description ?? answer.error)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .pending, .slowDown: "Microsoft is still waiting for the code to be entered"
        case .declined: "The sign-in was turned down on Microsoft's page"
        case .expired: "The code ran out before it was entered"
        case .refused(let why): "Microsoft refused the sign-in: \(why)"
        case .unreadable: "Microsoft answered with something that is not a sign-in"
        }
    }
}
