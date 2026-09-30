import Foundation
import Testing

@testable import SakeKit

@Test func theLayoutIsTheOneDocumented() {
    let paths = Paths(
        root: URL(filePath: "/tmp/support"),
        cache: URL(filePath: "/tmp/cache")
    )

    #expect(paths.engine.path == "/tmp/support/engine")
    #expect(paths.bottles.path == "/tmp/support/bottles")
    #expect(paths.downloads.path == "/tmp/cache/dl")
    #expect(paths.sources.path == "/tmp/cache/sources")
    #expect(paths.toolchain.path == "/tmp/cache/toolchain")
    #expect(paths.build.path == "/tmp/cache/build")
    #expect(paths.wineBuild.path == "/tmp/cache/build/wine")
    #expect(paths.wineUnixLibraries.path == "/tmp/support/engine/lib/wine/x86_64-unix")
    #expect(paths.d3dMetalFramework.path == "/tmp/support/engine/lib/external/D3DMetal.framework")
    #expect(paths.gdkRuntime.path == "/tmp/support/engine/lib/xgameruntime")
    #expect(paths.gdkRuntimeBuild.path == "/tmp/cache/build/xgameruntime")
    #expect(paths.bottle(named: "default").path == "/tmp/support/bottles/default")
}

@Test func theRosettaBridgeSitsBesideTheFrameworkItResolves() {
    let paths = Paths(
        root: URL(filePath: "/tmp/support"),
        cache: URL(filePath: "/tmp/cache")
    )

    // libd3dshared resolves `@rpath/D3DMetal.framework/D3DMetal` relative to its own
    // location, so moving one of these without the other breaks D3DMetal with no symptom
    // that names either file. See docs/runtime.md.
    #expect(
        paths.d3dSharedLibrary.deletingLastPathComponent().path
            == paths.d3dMetalFramework.deletingLastPathComponent().path
    )
    #expect(paths.d3dSharedLibrary.lastPathComponent == "libd3dshared.dylib")
}

@Test func aLoaderPathSonameReachesTheEngineLibraries() {
    let paths = Paths(
        root: URL(filePath: "/tmp/support"),
        cache: URL(filePath: "/tmp/cache")
    )

    // Wine dlopens the engine's dylibs from its unix libraries and nowhere else, so this is
    // the one relationship a rewritten soname depends on. Move either end without the other
    // and Wine asks dyld for a path that is not there. See docs/layout.md.
    let resolved = paths.wineUnixLibraries
        .appending(path: WineBuilder.engineLibrariesFromWineUnix)
        .standardizedFileURL

    #expect(resolved.path == paths.engine.appending(path: "lib").path)
}

@Test func theDefaultRootsAreOutsideTheAppBundleAndFreeOfSpaces() {
    let paths = Paths.default
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    #expect(paths.root.path == "\(home)/Library/Sake")
    #expect(paths.cache.path == "\(home)/Library/Caches/Sake")
    // A space in the engine path breaks every autotools configure. See docs/layout.md.
    #expect(!paths.engine.path.dropFirst(home.count).contains(" "))
}
