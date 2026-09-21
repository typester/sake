import Foundation

/// One of Wine's own programs, run in a bottle.
///
/// sake does not reimplement what these offer. The Windows version, the DLL overrides, the
/// drives and the audio device are all winecfg's panels, and what they set is the bottle's
/// registry — which `docs/runtime.md` records as being flushed lazily by wineserver, so a
/// copy of it in a SwiftUI form would be a second copy that lies. What sake does is hand
/// the bottle over.
public enum WineTool: String, CaseIterable, Sendable, Identifiable {
    case configuration = "winecfg"
    case registry = "regedit"
    case programs = "uninstaller"
    case processes = "taskmgr"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .configuration: "Wine Configuration"
        case .registry: "Registry Editor"
        case .programs: "Installed Programs"
        case .processes: "Task Manager"
        }
    }

    /// Wine resolves the bare name from the engine's own `x86_64-windows` directory, which
    /// is where the tools ship; there is no binary for them in `bin/`.
    public func command(in bottle: Bottle) -> Command {
        bottle.command("wine", [rawValue], workingDirectory: bottle.driveC)
    }

    public func logURL(in paths: Paths) -> URL {
        paths.build.appending(path: "tool-\(rawValue).log")
    }

    /// Started and then left alone: these are windows somebody closes themselves, so there
    /// is nothing to report progress on and nothing to wait for.
    public func start(in bottle: Bottle, runner: ProcessRunner = ProcessRunner()) async {
        try? FileManager.default.createDirectory(
            at: bottle.paths.build, withIntermediateDirectories: true
        )
        let log = try? LogFile(at: logURL(in: bottle.paths))
        defer { log?.close() }
        _ = try? await runner.run(command(in: bottle)) { line in log?.write(line.text + "\n") }
    }

    /// Whether any of them can be started at all, as a sentence.
    ///
    /// Asked before the menu is offered rather than reported after a failure: there is no
    /// useful recovery from "the engine is not built", and a menu item that can only fail
    /// is worse than no menu.
    public static func missingPrerequisite(in bottle: Bottle) -> String? {
        guard FileManager.default.fileExists(atPath: bottle.paths.engine.appending(path: "bin/wine").path)
        else {
            return "Wine is not built yet, so there are no tools to run. Finish setting up first."
        }
        guard bottle.exists else {
            return "There is no bottle to run them in yet. Create one first."
        }
        return nil
    }
}
