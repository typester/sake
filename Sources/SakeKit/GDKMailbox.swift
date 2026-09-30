import Foundation

/// Where a GDK title's runtime and sake talk, in the bottle the title runs in: one folder
/// per title ID, in which the runtime writes `request` and sake writes `answer` and, once
/// the person is signed in, `session`. Every file is `key value` lines under a first line
/// naming the format. See docs/gdk.md.
///
/// Files rather than a socket: Wine's Winsock has no `AF_UNIX`, so a Windows DLL cannot
/// reach anything sake listens on.
public struct GDKMailbox: Sendable {
    public let bottle: Bottle

    public init(bottle: Bottle) {
        self.bottle = bottle
    }

    /// `%LOCALAPPDATA%\Sake`. Every bottle's Windows user is `crossover`.
    public var directory: URL {
        bottle.driveC.appending(path: "users/crossover/AppData/Local/Sake")
    }

    public struct Request: Sendable, Hashable {
        public let bottle: String
        public let titleID: String
        public let id: String
    }

    public enum Answer: Sendable, Equatable {
        /// sake has the request and is signing the person in.
        case waiting
        case signedIn
        case failed(String)
        case cancelled
    }

    static let format = "sake 1"

    /// Longer than a device code lives, which is as long as a runtime waits for an answer.
    static let stale: TimeInterval = 20 * 60

    /// The requests no answer has settled yet. One that has gone stale is taken away, and
    /// one whose answer still says `waiting` is offered again: the sake that wrote it is gone.
    public func requests(now: Date = Date()) -> [Request] {
        let manager = FileManager.default
        let titles = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        var found: [Request] = []
        for titleID in titles.sorted() where titleID.count <= 8 && UInt32(titleID, radix: 16) != nil {
            let folder = directory.appending(path: titleID)
            let file = folder.appending(path: "request")
            guard let id = Self.read(file)?["request"], Self.isRequestID(id) else { continue }

            let written = (try? manager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            if let written, now.timeIntervalSince(written) > Self.stale {
                try? manager.removeItem(at: file)
                continue
            }
            if let answered = Self.read(folder.appending(path: "answer")), answered["request"] == id,
               answered["state"] != "waiting" {
                continue
            }
            found.append(Request(bottle: bottle.name, titleID: titleID, id: id))
        }
        return found
    }

    public func answer(_ request: Request, with answer: Answer) throws {
        var lines = ["request \(request.id)"]
        switch answer {
        case .waiting: lines.append("state waiting")
        case .signedIn: lines.append("state signed-in")
        case .failed(let reason): lines += ["state failed", "reason \(Self.oneLine(reason))"]
        case .cancelled: lines.append("state cancelled")
        }
        try Self.write(lines, to: folder(for: request).appending(path: "answer"))
    }

    /// Before the answer that says `signed-in`, since the runtime reads it on seeing that.
    /// Which token a URL takes is written here, by host, so that the runtime knows no table
    /// of its own.
    public func write(_ session: XboxSession, for request: Request, relyingParties: [RelyingParty]) throws {
        let user = session.user
        var lines: [String] = []
        for (key, value) in [
            ("xuid", user.xuid), ("gamertag", user.gamertag), ("user-hash", user.userHash),
            ("age-group", user.ageGroup), ("privileges", user.privileges),
        ] {
            if let value { lines.append("\(key) \(Self.oneLine(value))") }
        }
        for (relyingParty, token) in session.tokens.sorted(by: { $0.key < $1.key }) {
            lines.append("token \(relyingParty) \(Int(token.notAfter.timeIntervalSince1970)) \(token.token)")
        }
        let endpoints = relyingParties.filter { session.tokens[$0.name] != nil }
            .flatMap { relyingParty in relyingParty.hosts.map { ($0, relyingParty.name) } }
        for (host, relyingParty) in endpoints.sorted(by: { $0.0 < $1.0 }) {
            lines.append("endpoint \(host) \(relyingParty)")
        }
        try Self.write(lines, to: folder(for: request).appending(path: "session"), ownerOnly: true)
    }

    /// Takes the request away once it has its final answer, unless the runtime has asked
    /// again in the meantime.
    public func finish(_ request: Request) {
        let file = folder(for: request).appending(path: "request")
        if Self.read(file)?["request"] == request.id {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func folder(for request: Request) -> URL {
        directory.appending(path: request.titleID)
    }

    /// The first of each key, from a file whose first line is ``format``.
    static func read(_ url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first == format else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, fields[parts[0]] == nil { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    /// A GUID in braces, which is what the runtime writes and all that is echoed back.
    static func isRequestID(_ text: String) -> Bool {
        text.count == 38 && text.hasPrefix("{") && text.hasSuffix("}")
            && UUID(uuidString: String(text.dropFirst().dropLast())) != nil
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Whole or not at all, so the runtime never reads half a file.
    private static func write(_ lines: [String], to url: URL, ownerOnly: Bool = false) throws {
        let text = ([format] + lines).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
        if ownerOnly {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

extension GDKMailbox {
    /// Every request in every bottle, each once, looked for every `interval` for as long as
    /// the stream is read.
    public static func watch(
        _ paths: Paths = .default,
        every interval: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AsyncStream<Request> {
        AsyncStream { continuation in
            let work = Task {
                var seen: Set<Request> = []
                while !Task.isCancelled {
                    for bottle in Bottle.all(in: paths) {
                        for request in GDKMailbox(bottle: bottle).requests(now: now())
                        where seen.insert(request).inserted {
                            continuation.yield(request)
                        }
                    }
                    do { try await sleep(interval) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
