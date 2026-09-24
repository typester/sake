import Foundation

/// Where sake keeps things on disk, as `docs/layout.md` specifies it.
///
/// `~/Library/Sake` and not `~/Library/Application Support/Sake`: the engine is an autotools
/// `--prefix`, and a space in it word-splits out of `CPPFLAGS` and `LDFLAGS` the moment any
/// configure script expands them. See docs/layout.md.
public struct Paths: Sendable, Equatable {
    public let root: URL
    public let cache: URL

    public init(root: URL, cache: URL) {
        self.root = root
        self.cache = cache
    }

    public static var `default`: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(
            root: home.appending(path: "Library/Sake"),
            cache: home.appending(path: "Library/Caches/Sake")
        )
    }

    public var engine: URL { root.appending(path: "engine") }
    public var bottles: URL { root.appending(path: "bottles") }

    /// One bottle is one `WINEPREFIX`, with the games inside it in `drive_c`.
    public func bottle(named name: String) -> URL { bottles.appending(path: name) }

    public var downloads: URL { cache.appending(path: "dl") }
    public var sources: URL { cache.appending(path: "sources") }
    public var toolchain: URL { cache.appending(path: "toolchain") }
    public var build: URL { cache.appending(path: "build") }

    /// Wine is built out of tree, which leaves its unpacked source as it came out of the
    /// tarball -- the only copy sake has of it.
    public var wineBuild: URL { build.appending(path: "wine") }

    /// Wine's unix-side libraries, and the only place anything `dlopen`s the engine's dylibs
    /// from, so this is the directory a `@loader_path` soname resolves against. Nothing sits
    /// beside it for i386: under WoW64 the unix side is x86_64 only.
    public var wineUnixLibraries: URL { engine.appending(path: "lib/wine/x86_64-unix") }

    /// See ``GameBundle`` and docs/runtime.md.
    public var gameBundle: URL { engine.appending(path: "SakeGame.app") }

    /// `<key>/<program>.app` per program a title starts, keyed by a hash of the exe's path.
    /// The patched ntdll makes these (`patches/0007`); sake only passes the directory as
    /// `SAKE_GAME_BUNDLES`.
    public var programBundles: URL { engine.appending(path: "SakePrograms") }

    /// `redist/lib` out of Apple's image, kept as the user's own copy so the toolkit does
    /// not have to stay mounted to put D3DMetal back after a rebuild. See docs/licensing.md
    /// for why keeping it is inside the line and shipping it is not.
    public var d3dMetal: URL { cache.appending(path: "d3dmetal") }

    /// Apple's redistributable unpacks into the engine here. `libd3dshared.dylib` has to sit
    /// beside the framework rather than beside the `.so` files that load it: it resolves
    /// `@rpath/D3DMetal.framework/D3DMetal` relative to its own location. See docs/runtime.md.
    public var d3dMetalFramework: URL { engine.appending(path: "lib/external/D3DMetal.framework") }

    /// Apple's Rosetta bridge, in the same directory as the framework for the reason above.
    /// The D3DMetal install puts it there and every wine run names it, so it is spelled
    /// once. See docs/runtime.md.
    public var d3dSharedLibrary: URL { engine.appending(path: "lib/external/libd3dshared.dylib") }
}
