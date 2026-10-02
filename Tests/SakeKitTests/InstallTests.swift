import Foundation
import Testing

@testable import SakeKit

private func temporaryRoot() -> Paths {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-install-\(UUID().uuidString)")
    return Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
}

private func remove(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
}

/// An engine whose `wine` records how it was called, and a bottle to install into.
private func makeEngineAndBottle(_ paths: Paths, withBottle: Bool = true) throws {
    let bin = paths.engine.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

    let scripts = [
        "wine": """
            #!/bin/sh
            here="$(dirname "$0")"
            echo "$@" >> "$here/wine.args"
            pwd > "$here/wine.cwd"
            printenv WINEPREFIX > "$here/wine.wineprefix"
            echo "installing"
            exit 0
            """,
        "wineserver": """
            #!/bin/sh
            echo "$@" >> "$(dirname "$0")/wineserver.args"
            exit 0
            """,
    ]
    for (name, script) in scripts {
        let url = bin.appending(path: name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    guard withBottle else { return }
    let bottle = Bottle(paths: paths)
    try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
    try Data().write(to: bottle.systemRegistry)
}

/// An installer where the user downloaded it, which is outside the bottle on purpose.
private func makeInstaller(_ paths: Paths, named name: String) throws -> URL {
    let directory = paths.root.deletingLastPathComponent().appending(path: "Downloads")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try Data().write(to: url)
    return url
}

private func recorded(_ name: String, in paths: Paths) -> [String] {
    let text = (try? String(contentsOf: paths.engine.appending(path: "bin/\(name)"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
}

private func collect(_ stream: AsyncStream<InstallEvent>) async -> [InstallEvent] {
    var events: [InstallEvent] = []
    for await event in stream { events.append(event) }
    return events
}

@Test func anInstallerRunsInTheBottleFromWhereItSits() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngineAndBottle(paths)
    let installer = try makeInstaller(paths, named: "Battle.net-Setup.exe")

    let events = await collect(InstallerRunner(paths: paths, installer: installer).run())

    #expect(events.contains(.started(installer)))
    #expect(events.contains(.output("installing")))
    #expect(events.contains(.exited(status: 0)))
    #expect(recorded("wine.args", in: paths) == [installer.path])
    // An installer split across several files looks for the rest of itself beside the one
    // that was started, so it runs from its own directory rather than from the bottle.
    #expect(recorded("wine.cwd", in: paths).first?.hasSuffix("Downloads") == true)
    #expect(recorded("wine.wineprefix", in: paths) == [Bottle(paths: paths).url.path])
}

@Test func anInstallerFindsTheRuntimeAlreadyInTheBottle() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngineAndBottle(paths)
    let runtime = GDKRuntime(paths: paths)
    try FileManager.default.createDirectory(at: paths.gdkRuntime, withIntermediateDirectories: true)
    try Data("MZ \(GDKRuntime.marker)".utf8).write(to: runtime.dll)
    let bottle = Bottle(paths: paths)
    try FileManager.default.createDirectory(at: bottle.system32, withIntermediateDirectories: true)
    let installer = try makeInstaller(paths, named: "SteamSetup.exe")

    let runner = InstallerRunner(paths: paths, installer: installer)
    _ = await collect(runner.run())

    let placed = bottle.system32.appending(path: GDKRuntime.dllName)
    #expect(try Data(contentsOf: placed) == Data(contentsOf: runtime.dll))
    #expect(try String(contentsOf: runner.logURL, encoding: .utf8)
        .contains("=== xgameruntime placed in system32"))
}

@Test func anMsiIsHandedToMsiexecRatherThanRunDirectly() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngineAndBottle(paths)
    let installer = try makeInstaller(paths, named: "thing.msi")

    let command = InstallerRunner(paths: paths, installer: installer).command()
    #expect(command.arguments == ["msiexec", "/i", installer.path])
    // `arch` would strip every DYLD_* variable, and wine is x86_64 already.
    #expect(command.architecture == .native)
}

@Test func anInstallerLeavesALogToReadBack() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngineAndBottle(paths)
    let installer = try makeInstaller(paths, named: "Setup.exe")

    let runner = InstallerRunner(paths: paths, installer: installer)
    _ = await collect(runner.run())

    let log = try String(contentsOf: runner.logURL, encoding: .utf8)
    #expect(log.contains("=== install \(installer.path)"))
    #expect(log.contains("installing"))
    #expect(runner.logURL == Bottle(paths: paths).logs.appending(path: "install-Setup.log"))
}

@Test func whatCannotBeInstalledIsSaidRatherThanAttempted() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngineAndBottle(paths, withBottle: false)
    let installer = try makeInstaller(paths, named: "Setup.exe")

    // No bottle yet.
    #expect(InstallerRunner(paths: paths, installer: installer)
        .missingPrerequisite?.contains("Create one first") == true)

    try makeEngineAndBottle(paths)

    // Not an installer at all.
    let readme = try makeInstaller(paths, named: "readme.txt")
    #expect(InstallerRunner(paths: paths, installer: readme)
        .missingPrerequisite?.contains("a .exe or a .msi") == true)

    // Chosen, then moved or deleted before it was started.
    let gone = installer.deletingLastPathComponent().appending(path: "gone.exe")
    let runner = InstallerRunner(paths: paths, installer: gone)
    #expect(runner.missingPrerequisite?.contains("nothing at") == true)

    let events = await collect(runner.run())
    let failure = events.compactMap { event -> (String, URL?)? in
        if case .failed(let reason, let log) = event { (reason, log) } else { nil }
    }.first
    #expect(failure?.0.contains("nothing at") == true)
    // Nothing ran, so there is no log to send anyone to.
    #expect(failure?.1 == nil)
    #expect(recorded("wine.args", in: paths).isEmpty)
}
