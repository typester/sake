import Foundation

public enum InstallEvent: Sendable, Equatable {
    case started(URL)
    case output(String)
    case exited(status: Int32)
    case failed(reason: String, log: URL?)
    case finished
}

public enum InstallError: Error, Equatable, LocalizedError {
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let what): what
        }
    }
}

/// Runs an installer the user supplied inside one bottle.
///
/// sake never fetches one: accepting a game's terms and downloading its installer is the
/// user's act, the same line `licensing.md` draws around Apple's toolkit.
public struct InstallerRunner: Sendable {
    private let paths: Paths
    private let runner: ProcessRunner
    public let bottle: Bottle
    public let installer: URL

    public static let extensions = ["exe", "msi"]

    public init(
        paths: Paths = .default,
        name: String = Bottle.defaultName,
        installer: URL,
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.paths = paths
        self.runner = runner
        self.bottle = Bottle(paths: paths, name: name)
        self.installer = installer
    }

    public var logURL: URL {
        bottle.logs.appending(path: "install-\(installer.deletingPathExtension().lastPathComponent).log")
    }

    public var missingPrerequisite: String? {
        guard bottle.exists else {
            return "There is no bottle to install into yet. Create one first."
        }
        guard FileManager.default.fileExists(atPath: installer.path) else {
            return "There is nothing at \(installer.path) any more."
        }
        guard Self.extensions.contains(installer.pathExtension.lowercased()) else {
            return """
                \(installer.lastPathComponent) is not a Windows installer. \
                sake can run a .exe or a .msi.
                """
        }
        return nil
    }

    /// From the installer's own directory, because an installer split across several files
    /// looks for the rest of itself beside the one you started.
    public func command() -> Command {
        let arguments = installer.pathExtension.lowercased() == "msi"
            ? ["msiexec", "/i", installer.path]
            : [installer.path]
        return bottle.command(
            "wine", arguments, workingDirectory: installer.deletingLastPathComponent()
        )
    }

    public func run() -> AsyncStream<InstallEvent> {
        AsyncStream { continuation in
            let work = Task {
                do {
                    if let missing = missingPrerequisite { throw InstallError.notReady(missing) }
                    try FileManager.default.createDirectory(
                        at: bottle.logs, withIntermediateDirectories: true
                    )
                    let log = try LogFile(at: logURL)
                    defer { log.close() }

                    // Steam's installer can start Steam as it finishes, and a game installed in
                    // that Steam never passes through sake's Play.
                    GDKRuntime(paths: paths).place(in: bottle, loggingTo: log)
                    let command = self.command()
                    log.write("=== install \(command.arguments.joined(separator: " "))\n")
                    continuation.yield(.started(installer))

                    let result = try await runner.run(command) { line in
                        log.write(line.text + "\n")
                        continuation.yield(.output(line.text))
                    }
                    continuation.yield(.exited(status: result.exitStatus))
                } catch {
                    if Task.isCancelled {
                        // An installer is a Wine process like any other: its children are
                        // not in our process group and wineserver outlives it. See
                        // docs/runtime.md.
                        await takeDown()
                    } else {
                        continuation.yield(.failed(
                            reason: error.localizedDescription,
                            log: error is InstallError ? nil : logURL
                        ))
                    }
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Take the bottle down, then say how much of it is still up.
    ///
    /// An installer's own children carry neither its name nor the engine's path, so what
    /// is left is asked of the prefix. See ``Bottle/takeDown(runner:)``.
    @discardableResult
    public func stop() async -> [Int32] {
        await bottle.takeDown(runner: runner)
    }

    private func takeDown() async {
        let bottle = self.bottle
        let runner = self.runner
        await Task.detached { _ = await bottle.takeDown(runner: runner) }.value
    }
}
