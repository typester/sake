import Foundation
import Testing

@testable import SakeKit

private func temporaryRoot() -> Paths {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-bundle-\(UUID().uuidString)")
    return Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
}

private func remove(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
}

private let diablo = Title(
    id: "diablo-iv",
    name: "Diablo IV",
    executable: "Program Files (x86)/Diablo IV/Diablo IV.exe"
)

/// The shape of an installed engine, with D3DMetal's relative link in it.
private func makeEngine(_ paths: Paths) throws {
    let manager = FileManager.default
    let engine = paths.engine
    let unix = paths.wineUnixLibraries
    for directory in [
        unix, engine.appending(path: "lib/wine/x86_64-windows"),
        engine.appending(path: "lib/wine/i386-windows"), engine.appending(path: "lib/external"),
        engine.appending(path: "share/wine"), engine.appending(path: "bin"),
    ] {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("loader".utf8).write(to: unix.appending(path: "wine"))
    try Data("ntdll".utf8).write(to: unix.appending(path: "ntdll.so"))
    try Data("bridge".utf8).write(to: paths.d3dSharedLibrary)
    try Data("freetype".utf8).write(to: engine.appending(path: "lib/libfreetype.6.dylib"))
    try Data("archive".utf8).write(to: engine.appending(path: "lib/libgmp.a"))
    try Data("server".utf8).write(to: engine.appending(path: "bin/wineserver"))
    try manager.createSymbolicLink(
        atPath: unix.appending(path: "d3d11.so").path,
        withDestinationPath: "../../external/libd3dshared.dylib"
    )
}

private func isLink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
}

@Test func withoutAnEngineThereIsNoBundle() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let bundle = GameBundle(paths: paths)

    #expect(try bundle.prepare() == nil)
    #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
}

@Test func theBundleIsAGameWhoseExecutableIsWine() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngine(paths)
    let bundle = GameBundle(paths: paths)

    let wine = try bundle.prepare()

    #expect(wine == bundle.executableURL)
    #expect(bundle.url.path.hasPrefix(paths.engine.path))
    let plist = try PropertyListSerialization.propertyList(
        from: try Data(contentsOf: bundle.url.appending(path: "Contents/Info.plist")), format: nil
    ) as? [String: Any]
    #expect(plist?["CFBundleExecutable"] as? String == "wine")
    #expect(plist?["CFBundleIdentifier"] as? String == GameBundle.bundleIdentifier)
    #expect(plist?["LSApplicationCategoryType"] as? String == "public.app-category.games")
    #expect(plist?["LSUIElement"] as? Bool == true)
}

@Test func theUnixSideIsCopiedBecauseWineFollowsLinksOutOfTheBundle() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngine(paths)
    let bundle = GameBundle(paths: paths)
    try bundle.prepare()
    let macOS = bundle.url.appending(path: "Contents/MacOS")

    for name in ["wine", "ntdll.so"] {
        #expect(!isLink(macOS.appending(path: name)))
        #expect(FileManager.default.contentsEqual(
            atPath: macOS.appending(path: name).path,
            andPath: paths.wineUnixLibraries.appending(path: name).path
        ))
    }
}

@Test func everythingWineLooksForFromTheBundleResolves() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngine(paths)
    let bundle = GameBundle(paths: paths)
    try bundle.prepare()
    let macOS = bundle.url.appending(path: "Contents/MacOS")
    let manager = FileManager.default

    func resolves(_ relative: String, to expected: URL) {
        let found = macOS.appending(path: relative).resolvingSymlinksInPath()
        #expect(found.path == expected.resolvingSymlinksInPath().path, "\(relative)")
    }
    resolves("x86_64-windows", to: paths.engine.appending(path: "lib/wine/x86_64-windows"))
    resolves("i386-windows", to: paths.engine.appending(path: "lib/wine/i386-windows"))
    resolves("../../share/wine", to: paths.engine.appending(path: "share/wine"))
    resolves("../../bin/wineserver", to: paths.engine.appending(path: "bin/wineserver"))
    resolves("../../libfreetype.6.dylib", to: paths.engine.appending(path: "lib/libfreetype.6.dylib"))
    resolves("../external/libd3dshared.dylib", to: paths.d3dSharedLibrary)
    resolves("d3d11.so", to: paths.d3dSharedLibrary)
    #expect(manager.fileExists(atPath: macOS.appending(path: "x86_64-unix/ntdll.so").path))
    #expect(macOS.appending(path: "x86_64-unix/ntdll.so").resolvingSymlinksInPath().path
        == macOS.appending(path: "ntdll.so").resolvingSymlinksInPath().path)
    // Build leftovers are not what Wine loads.
    #expect(!manager.fileExists(atPath: bundle.url.appending(path: "libgmp.a").path))
}

@Test func aBundleThatMatchesTheEngineIsLeftAlone() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngine(paths)
    let bundle = GameBundle(paths: paths)
    try bundle.prepare()
    let before = try FileManager.default.attributesOfItem(atPath: bundle.url.path)[.systemFileNumber]

    try bundle.prepare()

    let after = try FileManager.default.attributesOfItem(atPath: bundle.url.path)[.systemFileNumber]
    #expect(before as? Int == after as? Int)
}

@Test func aRebuiltEngineIsCopiedAgain() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngine(paths)
    let bundle = GameBundle(paths: paths)
    try bundle.prepare()

    try Data("ntdll, rebuilt".utf8).write(to: paths.wineUnixLibraries.appending(path: "ntdll.so"))
    try FileManager.default.removeItem(at: paths.wineUnixLibraries.appending(path: "d3d11.so"))
    try bundle.prepare()

    let macOS = bundle.url.appending(path: "Contents/MacOS")
    #expect(FileManager.default.contents(atPath: macOS.appending(path: "ntdll.so").path)
        == Data("ntdll, rebuilt".utf8))
    #expect(!isLink(macOS.appending(path: "d3d11.so")))
    #expect(!FileManager.default.fileExists(atPath: macOS.appending(path: "d3d11.so").path))
}

@Test func oneBundleServesEveryTitleAndProgramBundlesGoBesideIt() {
    let paths = temporaryRoot()

    #expect(GameBundle(paths: paths).url == paths.engine.appending(path: "SakeGame.app"))
    #expect(paths.programBundles == paths.engine.appending(path: "SakePrograms"))
    // Hard links need the same volume, which is what being in the engine guarantees.
    #expect(paths.programBundles.deletingLastPathComponent() == paths.gameBundle.deletingLastPathComponent())
}

@Test func launchingThroughTheBundleChangesOnlyTheExecutable() {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let launcher = TitleLauncher(paths: paths, name: "default", title: diablo)
    let wine = GameBundle(paths: paths).executableURL

    let direct = launcher.command()
    let through = launcher.command(wine: wine)

    #expect(direct.executable == paths.engine.appending(path: "bin/wine"))
    #expect(through.executable == wine)
    #expect(through.arguments == direct.arguments)
    #expect(through.workingDirectory == direct.workingDirectory)
    #expect(through.environment?["SAKE_GAME_BUNDLES"] == paths.programBundles.path)
    #expect(direct.environment?["SAKE_GAME_BUNDLES"] == nil)
    var rest = through.environment
    rest?["SAKE_GAME_BUNDLES"] = nil
    #expect(rest == direct.environment)
}

@Test func whatThePatchedNtdllLeftBehindIsSweptAndItsBundlesAreNot() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeEngine(paths)
    let programs = paths.programBundles
    let manager = FileManager.default
    let key = "dd402fb5687d8ece"
    for name in [
        "\(key)/Diablo IV.app", "\(key)/.staging-123", "\(key)/.stale-456",
        // From before bundles were keyed by the exe's path.
        "Battle.net.app", ".stale-Battle.net-789",
    ] {
        try manager.createDirectory(at: programs.appending(path: name), withIntermediateDirectories: true)
    }

    try GameBundle(paths: paths).prepare()

    #expect(try manager.contentsOfDirectory(atPath: programs.path) == [key])
    #expect(try manager.contentsOfDirectory(atPath: programs.appending(path: key).path) == ["Diablo IV.app"])
}
