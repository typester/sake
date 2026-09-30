import Foundation

public enum SignInEvent: Sendable, Equatable {
    /// For the person to enter at `code.verificationURL`.
    case code(MicrosoftSignIn.DeviceCode)
    case signedIn(XboxSignInResult)
    case failed(reason: String)
    case finished
}

public struct XboxSignInResult: Sendable, Equatable {
    public let session: XboxSession
    /// Signs the same person in again without a code. It belongs with sake, not in a bottle.
    public let refreshToken: String
}

/// Who is signed in, and a token for each relying party a title asked for.
public struct XboxSession: Sendable, Equatable, Codable {
    public let user: XboxUser
    public let tokens: [String: XboxToken]
}

/// A key and the device it stands for. Tokens minted with one are bound to it, and every
/// request made with them has to be signed by it.
public struct XboxDevice: Sendable {
    public let key: ProofKey
    public let id: UUID

    public init(key: ProofKey, id: UUID) {
        self.key = key
        self.id = id
    }
}

/// One sign-in from start to finish: a refresh token if there is one that still works,
/// Microsoft's device code if not, then Xbox Live's tokens for each relying party.
///
/// With no ``XboxDevice`` the tokens are bound to nothing and nothing is signed, which is
/// the flow Microsoft documents for websites. Which of the two a title's runtime is handed
/// is docs/gdk.md's to say.
public struct XboxSignIn: Sendable {
    private let microsoft: MicrosoftSignIn
    private let xbox: XboxLiveAuth
    private let relyingParties: [String]
    private let device: XboxDevice?

    /// The relying party whose token names the person, and which every sign-in asks for.
    public static let identity = "http://xboxlive.com"

    public init(
        clientID: String,
        relyingParties: [String],
        device: XboxDevice? = nil,
        transport: HTTPTransport = .ephemeral(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        microsoft = MicrosoftSignIn(clientID: clientID, transport: transport, sleep: sleep, now: now)
        xbox = XboxLiveAuth(transport: transport, now: now)
        self.relyingParties = [Self.identity] + relyingParties.filter { $0 != Self.identity }
        self.device = device
    }

    public func run(refreshToken: String? = nil) -> AsyncStream<SignInEvent> {
        AsyncStream { continuation in
            let work = Task {
                do {
                    let tokens = try await microsoftTokens(refreshToken: refreshToken) { code in
                        continuation.yield(.code(code))
                    }
                    let session = try await xboxSession(accessToken: tokens.accessToken)
                    continuation.yield(.signedIn(XboxSignInResult(session: session, refreshToken: tokens.refreshToken)))
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.failed(reason: error.localizedDescription))
                    }
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// A refresh token Microsoft refuses has been revoked or has lapsed, and the way back is
    /// a new code rather than a failure.
    private func microsoftTokens(
        refreshToken: String?,
        show: (MicrosoftSignIn.DeviceCode) -> Void
    ) async throws -> MicrosoftSignIn.Tokens {
        if let refreshToken {
            do {
                return try await microsoft.refresh(refreshToken)
            } catch MicrosoftSignInError.refused(_) {}
        }
        let code = try await microsoft.requestCode()
        show(code)
        return try await microsoft.waitForApproval(of: code)
    }

    private func xboxSession(accessToken: String) async throws -> XboxSession {
        let key = device?.key
        let user = try await xbox.userToken(accessToken: accessToken, key: key)
        var deviceToken: XboxToken?
        if let device {
            deviceToken = try await xbox.deviceToken(key: device.key, deviceID: device.id)
        }

        var tokens: [String: XboxToken] = [:]
        for relyingParty in relyingParties {
            tokens[relyingParty] = try await xbox.xstsToken(
                relyingParty: relyingParty, userToken: user, deviceToken: deviceToken, key: key
            )
        }
        guard let person = tokens[Self.identity]?.user, person.xuid != nil else {
            throw XboxLiveError.anonymous
        }
        return XboxSession(user: person, tokens: tokens)
    }
}
