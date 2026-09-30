import Foundation

public enum GDKSignInEvent: Sendable, Equatable {
    /// For the person to enter at `code.verificationURL`, on behalf of the title named.
    case code(MicrosoftSignIn.DeviceCode, title: String)
    case signedIn(title: String)
    case failed(reason: String, title: String?)
    case cancelled
    case finished
}

extension GDKTitle {
    /// What the default endpoint table does not cover, by title ID. sake cannot read a
    /// title's own table without a title token. See docs/gdk.md.
    static let ownRelyingParties: [UInt32: [String]] = [
        // Minecraft Dungeons II
        0x6B9D_E498: ["rp://api.minecraftservices.com/"],
    ]

    /// Every relying party a sign-in for this title asks for, besides the one that names
    /// the person.
    public var relyingParties: [RelyingParty] {
        let own = UInt32(titleID, radix: 16).flatMap { Self.ownRelyingParties[$0] } ?? []
        return [.playFab] + own.map { RelyingParty($0) }
    }
}

/// One request from a title's runtime, answered: the title found in its bottle, the person
/// signed in, without a code when sake kept a sign-in for the title's app ID, and the
/// session written back. See docs/gdk.md.
public struct GDKSignIn: Sendable {
    public let request: GDKMailbox.Request
    private let paths: Paths
    private let transport: HTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        request: GDKMailbox.Request,
        paths: Paths = .default,
        transport: HTTPTransport = .ephemeral(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.request = request
        self.paths = paths
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    /// Stopping reading the stream is how the person's Cancel reaches the runtime.
    public func run() -> AsyncStream<GDKSignInEvent> {
        AsyncStream { continuation in
            let work = Task {
                let outcome = await answer { continuation.yield($0) }
                continuation.yield(outcome)
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func answer(showing show: (GDKSignInEvent) -> Void) async -> GDKSignInEvent {
        let bottle = Bottle(paths: paths, name: request.bottle)
        let mailbox = GDKMailbox(bottle: bottle)
        func settle(_ answer: GDKMailbox.Answer, _ event: GDKSignInEvent) -> GDKSignInEvent {
            try? mailbox.answer(request, with: answer)
            mailbox.finish(request)
            return event
        }
        func fail(_ reason: String, _ title: String?) -> GDKSignInEvent {
            settle(.failed(reason), .failed(reason: reason, title: title))
        }

        // Before the title is looked for, which walks the bottle's Program Files: on a USB disk
        // on 2026-09-30 a request waited 3.5 seconds to be picked up, most of it that walk,
        // and a runtime gives up on a sake that has said nothing for 10.
        do {
            try mailbox.answer(request, with: .waiting)
        } catch {
            return fail(error.localizedDescription, nil)
        }
        let wanted = UInt32(request.titleID, radix: 16)
        guard let title = GDKTitle.all(in: bottle).first(where: { UInt32($0.titleID, radix: 16) == wanted }) else {
            return fail("No MicrosoftGame.config in the bottle “\(bottle.name)” names title \(request.titleID).", nil)
        }
        guard let clientID = title.msaAppID else {
            return fail("\(title.name) names no Microsoft app ID to sign in with.", title.name)
        }

        let accounts = XboxAccounts(paths: paths)
        let kept = accounts.account(for: clientID)
        let device = (try? kept?.device()) ?? XboxDevice(key: ProofKey(), id: UUID())
        let signIn = XboxSignIn(
            clientID: clientID, relyingParties: title.relyingParties, device: device,
            transport: transport, sleep: sleep, now: now
        )

        for await event in signIn.run(refreshToken: kept?.refreshToken) {
            switch event {
            case .code(let code):
                show(.code(code, title: title.name))
            case .signedIn(let result):
                do {
                    try accounts.save(XboxAccount(refreshToken: result.refreshToken, device: device), for: clientID)
                    try mailbox.write(result.session, for: request)
                } catch {
                    return fail(error.localizedDescription, title.name)
                }
                return settle(.signedIn, .signedIn(title: title.name))
            case .failed(let reason):
                return fail(reason, title.name)
            case .finished:
                break
            }
        }
        return settle(.cancelled, .cancelled)
    }
}
