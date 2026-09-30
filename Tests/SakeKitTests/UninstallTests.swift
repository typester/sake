import Foundation
import Testing

@testable import SakeKit

private func temporaryRoot() -> (paths: Paths, container: URL) {
    let container = FileManager.default.temporaryDirectory
        .appending(path: "sake-uninstall-\(UUID().uuidString)")
    return (Paths(root: container.appending(path: "support"),
                  cache: container.appending(path: "cache")), container)
}

/// An engine whose `wineserver` records which prefix it was pointed at, and a bottle for
/// each name given.
private func makeTree(_ paths: Paths, bottles: [String] = ["default"]) throws {
    let manager = FileManager.default
    let bin = paths.engine.appending(path: "bin")
    try manager.createDirectory(at: bin, withIntermediateDirectories: true)

    let wineserver = """
        #!/bin/sh
        here="$(dirname "$0")"
        printenv WINEPREFIX >> "$here/wineserver.prefixes"
        exit 0
        """
    let url = bin.appending(path: "wineserver")
    try wineserver.write(to: url, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

    for name in bottles {
        let bottle = Bottle(paths: paths, name: name)
        try manager.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        try Data().write(to: bottle.systemRegistry)
    }

    for directory in [paths.downloads, paths.sources, paths.build, paths.d3dMetal] {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data().write(to: paths.d3dMetal.appending(path: "libd3dshared.dylib"))
}

/// A trash that keeps what it is handed, outside both roots so that it survives them.
private func trash(besides paths: Paths, in container: URL) -> (can: URL, trash: Trash) {
    let can = container.appending(path: "trash")
    return (can, Trash { url in
        try FileManager.default.createDirectory(at: can, withIntermediateDirectories: true)
        let landed = can.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: landed)
        return landed
    })
}

private func collect(_ stream: AsyncStream<UninstallEvent>) async -> [UninstallEvent] {
    var events: [UninstallEvent] = []
    for await event in stream { events.append(event) }
    return events
}

@Test func whatUninstallingTakesAwayIsListedAPieceAtATime() throws {
    let (paths, container) = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: container) }
    try makeTree(paths, bottles: ["default", "spare"])

    let items = Uninstaller(paths: paths).items()

    #expect(items.map(\.id) == ["engine", "bottle-default", "bottle-spare", "cache"])
    #expect(items.map(\.name).contains("Bottle “spare”"))
    // Every line is inside one of the two directories that actually move.
    #expect(items.allSatisfy { item in
        Uninstaller(paths: paths).roots.contains { item.url.path.hasPrefix($0.path) }
    })
}

@Test func nothingThatIsNotThereIsOffered() throws {
    let (paths, container) = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: container) }
    try FileManager.default.createDirectory(at: paths.engine, withIntermediateDirectories: true)

    // No bottles and no cache: an install that stopped after the engine was built.
    #expect(Uninstaller(paths: paths).items().map(\.id) == ["engine"])
}

@Test func everyBottleIsTakenDownBeforeAnythingIsMoved() async throws {
    let (paths, container) = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: container) }
    try makeTree(paths, bottles: ["default", "spare"])
    let (_, can) = trash(besides: paths, in: container)

    let events = await collect(Uninstaller(paths: paths).run(trash: can))

    let order = events.compactMap { event -> String? in
        switch event {
        case .stopping(let bottle): "stop \(bottle)"
        case .removing: "remove"
        default: nil
        }
    }
    #expect(order == ["stop default", "stop spare", "remove", "remove"])
}

@Test func theKillIsPointedAtEachPrefixRatherThanTheDefaultWinePrefix() async throws {
    let (paths, container) = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: container) }
    try makeTree(paths, bottles: ["default", "spare"])
    let (can, injected) = trash(besides: paths, in: container)

    _ = await collect(Uninstaller(paths: paths).run(trash: injected))

    // The recording survives because the engine went to the trash rather than away.
    let recorded = try String(
        contentsOf: can.appending(path: "support/engine/bin/wineserver.prefixes"),
        encoding: .utf8
    ).split(separator: "\n").map(String.init)
    #expect(recorded == [paths.bottle(named: "default").path, paths.bottle(named: "spare").path])
}

@Test func onlyTheTwoRootsMoveAndNothingBesideThem() async throws {
    let (paths, container) = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: container) }
    try makeTree(paths)
    let neighbour = container.appending(path: "someone else's files")
    try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
    let (can, injected) = trash(besides: paths, in: container)

    let events = await collect(Uninstaller(paths: paths).run(trash: injected))

    #expect(events.contains(.finished(removed: 2)))
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
    #expect(!FileManager.default.fileExists(atPath: paths.cache.path))
    #expect(FileManager.default.fileExists(atPath: neighbour.path))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: can.path))?.sorted()
        == ["cache", "support"])
}

@Test func theUsersCopyOfD3DMetalGoesWithTheCache() async throws {
    let (paths, container) = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: container) }
    try makeTree(paths)
    let (_, injected) = trash(besides: paths, in: container)

    // docs/licensing.md is binding on this: the copy is the user's, made on their machine,
    // and it does not outlive the cache it was kept in.
    #expect(paths.d3dMetal.path.hasPrefix(paths.cache.path))
    #expect(FileManager.default.fileExists(atPath: paths.d3dMetal.path))

    _ = await collect(Uninstaller(paths: paths).run(trash: injected))

    #expect(!FileManager.default.fileExists(atPath: paths.d3dMetal.path))
}

@Test func aRootThatIsAlreadyGoneIsNotHandedToTheTrash() async throws {
    let (paths, container) = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: container) }
    try makeTree(paths)
    try FileManager.default.removeItem(at: paths.cache)
    let (can, injected) = trash(besides: paths, in: container)

    let events = await collect(Uninstaller(paths: paths).run(trash: injected))

    #expect(events.contains(.finished(removed: 1)))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: can.path)) == ["support"])
}

@Test func aKeptSignInIsListedAndGoesWithTheRoot() async throws {
    let (paths, container) = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: container) }
    try makeTree(paths)
    try XboxAccounts(paths: paths).save(
        XboxAccount(refreshToken: "a-refresh-token", device: XboxDevice(key: ProofKey(), id: UUID())),
        for: "0000000012345678"
    )
    let (can, injected) = trash(besides: paths, in: container)

    #expect(Uninstaller(paths: paths).items().map(\.id) == ["engine", "bottle-default", "sign-ins", "cache"])
    _ = await collect(Uninstaller(paths: paths).run(trash: injected))

    #expect(!FileManager.default.fileExists(atPath: paths.signIns.path))
    #expect(FileManager.default.fileExists(
        atPath: can.appending(path: "support/sign-ins/0000000012345678.json").path
    ))
}
