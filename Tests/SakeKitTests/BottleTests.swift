import Foundation
import Testing

@testable import SakeKit

private func temporaryRoot() -> Paths {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-bottle-\(UUID().uuidString)")
    return Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
}

private func remove(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
}

/// An engine whose `wine` and `wineserver` are shell scripts. They record how they were
/// called and with what environment, and `wineboot` populates the prefix the way a real one
/// does -- or, with the flags below, the way the two failures that matter do.
private func makeFakeEngine(in paths: Paths, wow64: Bool = true, freeType: Bool = true) throws {
    let bin = paths.engine.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

    let wine = """
        #!/bin/sh
        here="$(dirname "$0")"
        echo "$@" >> "$here/wine.args"
        env | sort > "$here/wine.env"
        if [ "$1" = wineboot ]; then
            mkdir -p "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/drive_c/windows/syswow64"
            : > "$WINEPREFIX/system.reg"
            : > "$WINEPREFIX/drive_c/windows/system32/ntdll.dll"
            : > "$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
            \(wow64 ? ": > \"$WINEPREFIX/drive_c/windows/syswow64/ntdll.dll\"" : "true")
            \(freeType ? "true" : "echo '\(BottleBuilder.freeTypeMissing).' >&2")
            echo "wineboot: the prefix is up"
        fi
        exit 0
        """

    let wineserver = """
        #!/bin/sh
        here="$(dirname "$0")"
        echo "$@" >> "$here/wineserver.args"
        printenv WINEPREFIX >> "$here/wineserver.prefixes"
        exit 0
        """

    for (name, script) in [("wine", wine), ("wineserver", wineserver)] {
        let url = bin.appending(path: name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private func recorded(_ name: String, in paths: Paths) -> [String] {
    let url = paths.engine.appending(path: "bin/\(name)")
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
}

private func collect(_ stream: AsyncStream<BottleEvent>) async -> [BottleEvent] {
    var events: [BottleEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func failure(in events: [BottleEvent]) -> (reason: String, log: URL?)? {
    events.compactMap { event -> (String, URL?)? in
        if case .failed(let reason, let log) = event { (reason, log) } else { nil }
    }.first
}

private func phases(in events: [BottleEvent]) -> [BottlePhase] {
    events.compactMap { event in
        if case .phase(let phase) = event { phase } else { nil }
    }
}

@Test func thePhasesRunInOrderAndTheBottleReportsWhatLanded() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    let builder = BottleBuilder(paths: paths)
    let events = await collect(builder.create())

    #expect(phases(in: events) == [.boot, .settle, .verify, .registry])
    #expect(events.contains(.created(system32: 2, sysWoW64: 1)))
    #expect(builder.bottle.exists)
    #expect(builder.bottle.url.path == paths.bottles.appending(path: "default").path)
}

@Test func theCrashDialogIsTurnedOffBeforeAnythingCanCrash() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    _ = await collect(BottleBuilder(paths: paths).create())

    // It has to be the first thing after the prefix exists, because a crash before it puts
    // up winedbg's dialog and holds the process until somebody clicks Close.
    let calls = recorded("wine.args", in: paths)
    #expect(calls.first == "wineboot --init")
    #expect(calls.last?.contains(#"reg add HKCU\Software\Wine\WineDbg"#) == true)
    #expect(calls.last?.contains("ShowCrashDialog /t REG_DWORD /d 0 /f") == true)
}

@Test func everySettingAWineRunNeedsReachesTheProcess() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    _ = await collect(BottleBuilder(paths: paths).create())

    let environment = recorded("wine.env", in: paths)
    #expect(environment.contains("WINEPREFIX=\(paths.bottles.appending(path: "default").path)"))
    // Without this wineboot waits forever on the Wine Mono installer's dialog.
    #expect(environment.contains("WINEDLLOVERRIDES=mscoree,mshtml=d"))
    // err+all turns a cleanly handled dlopen failure into a crash.
    #expect(environment.contains("WINEDEBUG=-all"))
    // CW Hack 22996, without which Battle.net never loads its login page.
    #expect(environment.contains("WINE_SIMULATE_WRITECOPY=1"))
}

@Test func theRosettaBridgeIsNamedOnlyWhenItIsReallyThere() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let bottle = Bottle(paths: paths)

    // A variable pointing at nothing would read as "D3DMetal is set up" everywhere
    // downstream, and Diablo IV's silent deadlock is what that costs.
    #expect(bottle.environment(inheriting: [:])["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == nil)

    try FileManager.default.createDirectory(
        at: paths.d3dSharedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data().write(to: paths.d3dSharedLibrary)

    #expect(
        bottle.environment(inheriting: [:])["CX_APPLEGPTK_LIBD3DSHARED_PATH"]
            == paths.d3dSharedLibrary.path
    )
}

@Test func aWineRunIsNeverTranslated() {
    let paths = temporaryRoot()
    defer { remove(paths) }

    let command = Bottle(paths: paths).command("wine", ["wineboot"], inheriting: [:])

    // `arch` is a hardened system binary, so exec'ing it strips every DYLD_* variable --
    // and Wine's binaries are x86_64 already. Only the build is wrapped.
    #expect(command.architecture == .native)
    #expect(command.executable.path == paths.engine.appending(path: "bin/wine").path)
}

@Test func anEmptySysWoW64IsNotAWorkingBottle() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths, wow64: false)

    let events = await collect(BottleBuilder(paths: paths).create())

    #expect(failure(in: events)?.reason.contains("32-bit") == true)
    #expect(phases(in: events).contains(.registry) == false)
}

@Test func aWineThatCannotLoadFreeTypeIsNotAWorkingBottle() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths, freeType: false)

    let events = await collect(BottleBuilder(paths: paths).create())

    // The one cheap sign that the @loader_path sonames do not resolve for a running Wine.
    #expect(failure(in: events)?.reason.contains("FreeType") == true)
}

@Test func aRunThatFailedLeavesNoWineserverHoldingTheBottle() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths, wow64: false)

    _ = await collect(BottleBuilder(paths: paths).create())

    // `-w` waits, `-k` kills. Both have to have happened, and the kill has to have been
    // pointed at this prefix rather than the default ~/.wine.
    #expect(recorded("wineserver.args", in: paths) == ["-w", "-k"])
    let prefixes = recorded("wineserver.prefixes", in: paths)
    #expect(prefixes.allSatisfy { $0 == paths.bottles.appending(path: "default").path })
}

@Test func takingABottleDownNamesItsOwnPrefix() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    _ = try await Bottle(paths: paths).stop()

    // Without WINEPREFIX, `wineserver -k` goes after ~/.wine, kills nothing and exits 0.
    #expect(recorded("wineserver.args", in: paths) == ["-k"])
    #expect(recorded("wineserver.prefixes", in: paths) == [paths.bottles.appending(path: "default").path])
}

@Test func aBottleThatExistsIsNotBootedAgain() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    let builder = BottleBuilder(paths: paths)
    _ = await collect(builder.create())
    try FileManager.default.removeItem(at: paths.engine.appending(path: "bin/wine.args"))

    let second = await collect(builder.create())

    #expect(second == [.alreadyCreated(system32: 2, sysWoW64: 1), .finished])
    #expect(recorded("wine.args", in: paths).isEmpty)
}

@Test func missingWineIsNamedRatherThanRunInto() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }

    let builder = BottleBuilder(paths: paths)
    #expect(builder.missingPrerequisite?.contains("Build Wine first") == true)

    let events = await collect(builder.create())
    #expect(failure(in: events)?.reason.contains("Build Wine first") == true)
    // Nothing ran, so there is no log to send anyone to.
    #expect(failure(in: events)?.log == nil)
}

@Test func theWholeRunGoesToALogEvenThoughTheUISeesLines() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    let builder = BottleBuilder(paths: paths)
    let events = await collect(builder.create())

    let log = try String(contentsOf: builder.logURL, encoding: .utf8)
    #expect(log.contains("=== boot"))
    #expect(log.contains("=== verify system32 2 / syswow64 1 files"))
    #expect(log.contains("=== verify Wine loaded FreeType from the engine"))
    #expect(events.contains(.output("wineboot: the prefix is up")))
}

@Test func onlyFinishedPrefixesCountAsBottles() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    #expect(Bottle.all(in: paths).isEmpty)

    _ = await collect(BottleBuilder(paths: paths, name: "second").create())
    _ = await collect(BottleBuilder(paths: paths, name: "first").create())
    // What a run that was stopped part way leaves: a directory and no registry.
    try FileManager.default.createDirectory(
        at: paths.bottle(named: "half"), withIntermediateDirectories: true
    )

    #expect(Bottle.all(in: paths).map(\.name) == ["first", "second"])
}

@Test func aSecondBottleIsItsOwnPrefixAndItsOwnGames() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    let game = Title(
        id: "battle-net", name: "Battle.net",
        executable: "Program Files (x86)/Battle.net/Battle.net.exe"
    )

    for name in [Bottle.defaultName, "testing"] {
        _ = await collect(BottleBuilder(paths: paths, name: name).create())
    }
    let first = Bottle(paths: paths, name: Bottle.defaultName)
    let second = Bottle(paths: paths, name: "testing")
    try FileManager.default.createDirectory(
        at: game.directoryURL(in: first), withIntermediateDirectories: true
    )
    try Data().write(to: game.executableURL(in: first))
    try TitleStore(bottle: first).add(game)

    #expect(first.url != second.url)
    #expect(Title.installed(in: first).map(\.id) == [game.id])
    #expect(Title.installed(in: second).isEmpty)
}

@Test func aNameWithSpacesIsFineAndReachesWineWhole() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    // The rule against spaces in paths is about the engine, which is an autotools
    // --prefix. A bottle name is an environment value sake composes and no shell sees.
    #expect(Bottle.problem(withName: "old saves", in: paths) == nil)

    _ = await collect(BottleBuilder(paths: paths, name: "old saves").create())

    let environment = recorded("wine.env", in: paths)
    #expect(environment.contains("WINEPREFIX=\(paths.bottle(named: "old saves").path)"))
    #expect(Bottle.all(in: paths).map(\.name) == ["old saves"])
}

@Test func aNameThatWouldNotMakeOneBottleIsRefused() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    _ = await collect(BottleBuilder(paths: paths).create())

    #expect(Bottle.proposedName(from: "  spaced  ") == "spaced")
    #expect(Bottle.problem(withName: "", in: paths)?.contains("needs a name") == true)
    #expect(Bottle.problem(withName: "   ", in: paths)?.contains("needs a name") == true)
    #expect(Bottle.problem(withName: "a/b", in: paths)?.contains("slash") == true)
    #expect(Bottle.problem(withName: "..", in: paths)?.contains("dot") == true)
    #expect(Bottle.problem(withName: ".hidden", in: paths)?.contains("dot") == true)

    // APFS is case-insensitive by default, so this would be the same directory and the
    // second wineboot would run inside the first bottle.
    #expect(Bottle.problem(withName: "default", in: paths)?.contains("already") == true)
    #expect(Bottle.problem(withName: "DEFAULT", in: paths)?.contains("default") == true)
    #expect(Bottle.problem(withName: " default ", in: paths)?.contains("already") == true)

    #expect(Bottle.problem(withName: "testing", in: paths) == nil)
}

/// A trash that keeps what it is handed, so a test can look at it afterwards -- and so that
/// running the tests does not fill the developer's own.
private func trash(in paths: Paths) -> (can: URL, trash: Trash) {
    let can = paths.root.appending(path: "trash")
    return (can, Trash { url in
        try FileManager.default.createDirectory(at: can, withIntermediateDirectories: true)
        let landed = can.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: landed)
        return landed
    })
}

@Test func aRenamedBottleIsTheSamePrefixUnderAnotherName() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    let game = Title(
        id: "battle-net", name: "Battle.net",
        executable: "Program Files (x86)/Battle.net/Battle.net.exe"
    )

    _ = await collect(BottleBuilder(paths: paths).create())
    let before = Bottle(paths: paths)
    try FileManager.default.createDirectory(
        at: game.directoryURL(in: before), withIntermediateDirectories: true
    )
    try Data().write(to: game.executableURL(in: before))
    try TitleStore(bottle: before).add(game)

    let after = try await before.rename(to: "old saves")

    #expect(Bottle.all(in: paths).map(\.name) == ["old saves"])
    #expect(after.url.path == paths.bottle(named: "old saves").path)
    #expect(after.exists)
    // Renaming is not a copy: what was in the prefix is in it still -- the game, the
    // registry wineboot wrote, and the list of titles, which is why that list lives in
    // the prefix at all.
    #expect(Title.installed(in: after).map(\.id) == [game.id])
    #expect(after.systemFileCounts() == (system32: 2, sysWoW64: 1))
}

@Test func aRenameThatOnlyChangesCaseIsStillARename() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    _ = await collect(BottleBuilder(paths: paths, name: "Spare").create())

    // APFS is case-insensitive by default, so the new name already "exists" before the
    // move. `moveItem` renames anyway -- measured 2026-09-19 -- and the bottle being
    // renamed is excluded from the collision check so that this can be reached at all.
    #expect(Bottle.problem(withName: "spare", in: paths) != nil)
    #expect(Bottle.problem(withName: "spare", in: paths, renaming: "Spare") == nil)

    let renamed = try await Bottle(paths: paths, name: "Spare").rename(to: "spare")

    #expect(renamed.name == "spare")
    #expect(Bottle.all(in: paths).map(\.name) == ["spare"])
}

@Test func renamingAndRemovingBothTakeTheBottleDownFirst() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    _ = await collect(BottleBuilder(paths: paths).create())
    try FileManager.default.removeItem(at: paths.engine.appending(path: "bin/wineserver.prefixes"))

    let renamed = try await Bottle(paths: paths).rename(to: "spare")
    _ = try await renamed.remove(trash: trash(in: paths).trash)

    // Both against the prefix they were given: `wineserver -k` without WINEPREFIX goes
    // after ~/.wine, kills nothing of the user's and exits 0.
    #expect(recorded("wineserver.prefixes", in: paths) == [
        paths.bottle(named: "default").path, paths.bottle(named: "spare").path,
    ])
}

@Test func aRemovedBottleGoesToTheTrashWholeRatherThanAway() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    _ = await collect(BottleBuilder(paths: paths, name: "spare").create())
    _ = await collect(BottleBuilder(paths: paths).create())
    let (can, trash) = trash(in: paths)

    let landed = try await Bottle(paths: paths, name: "spare").remove(trash: trash)

    #expect(landed?.path == can.appending(path: "spare").path)
    #expect(Bottle.all(in: paths).map(\.name) == ["default"])
    // Recoverable, which is the whole reason it is the Trash and not removeItem.
    #expect(FileManager.default.fileExists(atPath: can.appending(path: "spare/system.reg").path))
}

@Test func aBottleCanBeThrownAwayWithNoEngineLeftToStopIt() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    _ = await collect(BottleBuilder(paths: paths).create())
    try FileManager.default.removeItem(at: paths.engine)

    // Nothing to kill is not a reason to refuse: a bottle outlives its engine.
    let landed = try await Bottle(paths: paths).remove(trash: trash(in: paths).trash)

    #expect(landed != nil)
    #expect(Bottle.all(in: paths).isEmpty)
}

@Test func throwingTheDefaultBottleAwaySendsSetupBackToIt() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    _ = await collect(BottleBuilder(paths: paths).create())
    let setup = Setup(paths: paths)

    #expect(setup.state(of: .bottle, machineIsReady: true) == .done)

    _ = try await Bottle(paths: paths).remove(trash: trash(in: paths).trash)

    #expect(setup.state(of: .bottle, machineIsReady: true) == .ready)
}

@Test func aNameNoOneCouldHaveTypedIsRefusedByTheRenameItself() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)
    for name in [Bottle.defaultName, "spare"] {
        _ = await collect(BottleBuilder(paths: paths, name: name).create())
    }
    let bottle = Bottle(paths: paths, name: "spare")

    // The sheet checks too, but the check that matters is the one no caller can skip.
    await #expect(throws: BottleError.badName("A bottle needs a name.")) {
        try await bottle.rename(to: "  ")
    }
    await #expect(throws: BottleError.self) { try await bottle.rename(to: "a/b") }
    await #expect(throws: BottleError.self) { try await bottle.rename(to: ".hidden") }
    await #expect(throws: BottleError.self) { try await bottle.rename(to: "DEFAULT") }

    #expect(Bottle.all(in: paths).map(\.name) == ["default", "spare"])
    // Its own name, trimmed to the same thing, is not a collision and not a move either.
    #expect(try await bottle.rename(to: " spare ").url == bottle.url)
}

@Test func aPrefixIsNamedByItsInodeSoARenameDoesNotLoseItsProcesses() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    let bottle = Bottle(paths: paths)
    try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)

    // wineserver's socket directory is the only thing on the machine that says which
    // prefix a Wine process belongs to. Measured against a live prefix on 2026-09-20.
    let attributes = try FileManager.default.attributesOfItem(atPath: bottle.url.path)
    let device = attributes[.systemNumber] as! Int
    let inode = attributes[.systemFileNumber] as! Int
    let expected = "/tmp/.wine-\(getuid())/server-"
        + String(device, radix: 16) + "-" + String(inode, radix: 16)
    #expect(bottle.serverDirectory?.path == expected)

    // An inode does not move when a directory is renamed, which is what makes this work
    // on a bottle somebody renamed while a game was running in it.
    let renamed = Bottle(paths: paths, name: "renamed")
    try FileManager.default.moveItem(at: bottle.url, to: renamed.url)
    #expect(renamed.serverDirectory?.path == expected)
}

@Test func aBottleThatIsASymlinkIsNamedByThePrefixItPointsAt() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }

    // The `ex` bottle on 2026-09-29: a link in bottles/ to a prefix on another disk. Wine
    // names the socket directory after the prefix, and the link's own inode names one that
    // never exists, so Stop found nothing to stop.
    let prefix = paths.root.appending(path: "elsewhere/ex")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.bottles, withIntermediateDirectories: true)
    let bottle = Bottle(paths: paths, name: "ex")
    try FileManager.default.createSymbolicLink(at: bottle.url, withDestinationURL: prefix)

    let attributes = try FileManager.default.attributesOfItem(atPath: prefix.path)
    let device = attributes[.systemNumber] as! Int
    let inode = attributes[.systemFileNumber] as! Int
    let expected = "/tmp/.wine-\(getuid())/server-"
        + String(device, radix: 16) + "-" + String(inode, radix: 16)
    #expect(bottle.serverDirectory?.path == expected)
}

@Test func aPrefixThatIsNotThereHasNoProcessesAndNothingToKill() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeEngine(in: paths)

    // No prefix at all: there is no inode to name a socket directory with.
    let missing = Bottle(paths: paths, name: "never-made")
    #expect(missing.serverDirectory == nil)
    #expect(await missing.processes().isEmpty)

    // A prefix that exists but has never been run has an inode and no socket directory.
    let bottle = Bottle(paths: paths)
    try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
    #expect(bottle.serverDirectory != nil)
    #expect(await bottle.processes().isEmpty)
    #expect(await bottle.takeDown().isEmpty)
    // It still went after the server, which is the half that needs WINEPREFIX set.
    #expect(recorded("wineserver.args", in: paths) == ["-k"])
}
