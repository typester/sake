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

/// A service a sign-in asks Xbox Live for a token to, named exactly as the endpoint table
/// names it.
public struct RelyingParty: Sendable, Hashable {
    public let name: String
    /// What a URL's host has to be, or end with after a dot, for its token to be this one.
    public let hosts: [String]
    /// Minted with the device's own token and bound to its key. A service that checks
    /// signatures then refuses the token on any request the key did not sign, and a title's
    /// runtime has no key, so only a service that wants a device gets one. See docs/gdk.md.
    public let boundToDevice: Bool

    public init(_ name: String, hosts: [String], boundToDevice: Bool = false) {
        self.name = name
        self.hosts = hosts
        self.boundToDevice = boundToDevice
    }

    /// The one whose token names the person, and which every sign-in asks for.
    public static let identity = RelyingParty("http://xboxlive.com", hosts: ["xboxlive.com"])

    /// The community stand-in's README says PlayFab refuses to link an account whose token
    /// came without a device, and the stand-in's is the one sign-in known to reach the game.
    public static let playFab = RelyingParty(
        "http://playfab.xboxlive.com/", hosts: ["playfabapi.com"], boundToDevice: true
    )
}

/// One sign-in from start to finish: a refresh token if there is one that still works,
/// Microsoft's device code if not, then Xbox Live's tokens for each relying party.
///
/// A token bound to nothing needs nothing signed, which is the flow Microsoft documents for
/// websites. Only a ``RelyingParty`` that is `boundToDevice` gets the ``XboxDevice``, and
/// with no device it is bound to nothing like the rest.
public struct XboxSignIn: Sendable {
    private let microsoft: MicrosoftSignIn
    private let xbox: XboxLiveAuth
    private let relyingParties: [RelyingParty]
    private let device: XboxDevice?

    public init(
        clientID: String,
        relyingParties: [RelyingParty],
        device: XboxDevice? = nil,
        transport: HTTPTransport = .ephemeral(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        microsoft = MicrosoftSignIn(clientID: clientID, transport: transport, sleep: sleep, now: now)
        xbox = XboxLiveAuth(transport: transport, now: now)
        self.relyingParties = [.identity] + relyingParties.filter { $0.name != RelyingParty.identity.name }
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

    /// A bound token has to come from a user token bound to the same key, so a sign-in that
    /// mints both kinds asks for two user tokens.
    private func xboxSession(accessToken: String) async throws -> XboxSession {
        let user = try await xbox.userToken(accessToken: accessToken, key: nil)
        var bound: (device: XboxDevice, user: XboxToken, token: XboxToken)?
        if let device, relyingParties.contains(where: \.boundToDevice) {
            bound = (
                device,
                try await xbox.userToken(accessToken: accessToken, key: device.key),
                try await xbox.deviceToken(key: device.key, deviceID: device.id)
            )
        }

        var tokens: [String: XboxToken] = [:]
        for relyingParty in relyingParties {
            if relyingParty.boundToDevice, let bound {
                tokens[relyingParty.name] = try await xbox.xstsToken(
                    relyingParty: relyingParty.name, userToken: bound.user, deviceToken: bound.token,
                    key: bound.device.key
                )
            } else {
                tokens[relyingParty.name] = try await xbox.xstsToken(
                    relyingParty: relyingParty.name, userToken: user, key: nil
                )
            }
        }
        guard let person = tokens[RelyingParty.identity.name]?.user, person.xuid != nil else {
            throw XboxLiveError.anonymous
        }
        return XboxSession(user: person, tokens: tokens)
    }
}
