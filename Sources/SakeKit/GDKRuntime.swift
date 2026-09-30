import Foundation

public enum GDKRuntimeError: Error, Equatable, LocalizedError {
    case notReady(String)
    case fetchFailed(String)
    case libHttpClientChanged(at: String)
    case compileFailed(status: Int32, log: String)
    case markerMissing(at: String)
    case notWritten(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let what):
            what
        case .fetchFailed(let reason):
            "libHttpClient could not be fetched: \(reason)"
        case .libHttpClientChanged(let at):
            """
            What libHttpClient unpacked to at \(at) is not the source sake pins, so it was \
            deleted rather than built.
            """
        case .compileFailed(let status, let log):
            "The GDK runtime failed to compile (exit \(status)). The full output is in \(log)."
        case .markerMissing(let at):
            """
            \(at) does not carry the string sake knows its own runtime by, so once placed in \
            a bottle it would never be updated.
            """
        case .notWritten(let path, let reason):
            "\(path) could not be written: \(reason)"
        }
    }

    var cameFromARun: Bool {
        switch self {
        case .compileFailed, .markerMissing: true
        case .notReady, .fetchFailed, .libHttpClientChanged, .notWritten: false
        }
    }
}

/// sake's own `xgameruntime.dll` as the engine keeps it, and a copy of it in a bottle.
///
/// Every bottle gets one before anything starts in it: sake starts Steam before Steam
/// installs a GDK game, so there is no telling which bottle will need it, and nothing but a
/// GDK title loads it. See docs/gdk.md.
public struct GDKRuntime: Sendable {
    public let paths: Paths

    public init(paths: Paths = .default) {
        self.paths = paths
    }

    public static let dllName = "xgameruntime.dll"

    /// libHttpClient's, which goes wherever a DLL built from it goes.
    public static let licenceName = "xgameruntime-libHttpClient-LICENSE.md"

    /// What `xgameruntime/src/main.cpp` compiles in, and what tells a copy of sake's from
    /// somebody else's. See ``place(in:)``.
    static let marker = "sake's own xgameruntime.dll"

    public var dll: URL { paths.gdkRuntime.appending(path: Self.dllName) }
    public var licence: URL { paths.gdkRuntime.appending(path: Self.licenceName) }

    public enum Placement: Sendable, Equatable, CustomStringConvertible {
        case notBuilt
        case placed
        case replaced
        case alreadyThere
        case leftAlone

        public var description: String {
            switch self {
            case .notBuilt: "not built yet, so nothing placed"
            case .placed: "placed in system32"
            case .replaced: "replaced an older copy of sake's in system32"
            case .alreadyThere: "already in system32"
            case .leftAlone: "left alone: the one in system32 is not sake's"
            }
        }
    }

    /// Put the engine's copy in the bottle's `system32`, unless it is there already or
    /// something that is not sake's is. `system32` is never made: without one there is no
    /// bottle, as with a symlinked bottle whose disk is not plugged in.
    public func place(in bottle: Bottle) throws -> Placement {
        guard let ours = try? Data(contentsOf: dll, options: .mappedIfSafe), Self.carriesMarker(ours)
        else { return .notBuilt }

        let target = bottle.system32.appending(path: Self.dllName)
        let outcome: Placement
        if FileManager.default.fileExists(atPath: target.path) {
            let there = try Data(contentsOf: target, options: .mappedIfSafe)
            if there == ours {
                outcome = .alreadyThere
            } else if Self.carriesMarker(there) {
                try Self.write(ours, to: target)
                outcome = .replaced
            } else {
                return .leftAlone
            }
        } else {
            try Self.write(ours, to: target)
            outcome = .placed
        }

        let licenceThere = bottle.system32.appending(path: Self.licenceName)
        if let text = try? Data(contentsOf: licence), (try? Data(contentsOf: licenceThere)) != text {
            try Self.write(text, to: licenceThere)
        }
        return outcome
    }

    /// ``place(in:)`` before a run, with what happened in the run's log. A failure is not the
    /// run's: most programs never load the DLL.
    func place(in bottle: Bottle, loggingTo log: LogFile) {
        let outcome: String
        do {
            outcome = try place(in: bottle).description
        } catch {
            outcome = "not placed: \(error.localizedDescription)"
        }
        log.write("=== xgameruntime \(outcome)\n")
    }

    static func carriesMarker(_ data: Data) -> Bool {
        data.range(of: Data(marker.utf8)) != nil
    }

    /// A file beside `url`, renamed over it, so that nothing ever sees half a DLL and a game
    /// that has the old one mapped keeps it. Not `Data.write(options: .atomic)`: when its
    /// rename fails with `EBUSY` it writes the file again where it is.
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).sake")
        do {
            try data.write(to: temporary)
        } catch {
            throw GDKRuntimeError.notWritten(path: url.path, reason: error.localizedDescription)
        }
        if Darwin.rename(temporary.path, url.path) == 0 { return }
        var failure = errno
        // What a DOS-style volume says when the name is taken.
        if failure == EINVAL, Darwin.unlink(url.path) == 0 {
            if Darwin.rename(temporary.path, url.path) == 0 { return }
            failure = errno
        }
        try? FileManager.default.removeItem(at: temporary)
        throw GDKRuntimeError.notWritten(path: url.path, reason: String(cString: strerror(failure)))
    }
}
