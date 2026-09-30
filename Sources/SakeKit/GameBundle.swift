import Foundation

/// The engine's `wine` inside an `.app` that declares itself a game, because Game Mode reads
/// a process's bundle and the engine's `wine` has none.
///
/// A bundle that merely starts `wine` is not enough: Wine starts every child process from its
/// own loader, so the loader itself has to be in `Contents/MacOS`. `patches/0007` gives each
/// program a title starts a bundle of its own mirrored from this one, so this one is shared
/// and never seen. It lives in the engine so that uninstalling the engine takes it with it.
/// See docs/runtime.md.
public struct GameBundle: Sendable, Equatable {
    public let paths: Paths

    public init(paths: Paths = .default) {
        self.paths = paths
    }

    public static let bundleIdentifier = "dev.typester.sake.game"

    public var url: URL { paths.gameBundle }

    public var executableURL: URL { url.appending(path: "Contents/MacOS/wine") }

    /// The bundle's `wine`, made or brought up to date, or `nil` when there is no engine to
    /// make it from.
    ///
    /// Left alone when it already matches the engine: a running title executes out of it,
    /// and every program bundle is a set of hard links to its files.
    @discardableResult
    public func prepare() throws -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.wineUnixLibraries.appending(path: "wine").path)
        else { return nil }

        let wanted = entries()
        if !isCurrent(wanted) {
            let staging = paths.engine.appending(path: ".SakeGame-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: staging) }
            for entry in wanted {
                try entry.make(in: staging)
            }
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: url)
            }
        }
        sweepPrograms()
        return executableURL
    }

    /// Removes the staging and stale copies the patched ntdll leaves beside program bundles,
    /// and unkeyed bundles from an older layout. They are hard links, so a program still
    /// running from one is unaffected.
    private func sweepPrograms() {
        let manager = FileManager.default
        let programs = paths.programBundles
        for key in Self.names(in: programs) {
            let directory = programs.appending(path: key)
            if key.hasPrefix(".") || key.hasSuffix(".app") {
                try? manager.removeItem(at: directory)
                continue
            }
            for name in Self.names(in: directory) where name.hasPrefix(".") {
                try? manager.removeItem(at: directory.appending(path: name))
            }
        }
    }

    /// Wine derives every other directory from the real path of `ntdll.so` — including the
    /// loader it starts child processes with — so the unix side is copied, not linked: a
    /// link resolves back into the engine and the children leave the bundle. Once `ntdll.so`
    /// is in a directory not called `lib/wine/x86_64-unix`, Wine looks for the rest relative
    /// to it, which is what the links are for. Measured on 2026-09-23, wine-11.0.
    func entries() -> [Entry] {
        let manager = FileManager.default
        let engine = paths.engine
        let lib = engine.appending(path: "lib")
        let unix = paths.wineUnixLibraries
        var entries: [Entry] = []

        for name in Self.names(in: unix) {
            let source = unix.appending(path: name)
            if let destination = try? manager.destinationOfSymbolicLink(atPath: source.path) {
                // Relative ones stay relative: `../../external/…` is what the `.so` links
                // D3DMetal installs, and the bundle has an `external` of its own for it.
                entries.append(Entry(path: "Contents/MacOS/\(name)", kind: .link(destination)))
            } else {
                entries.append(Entry(path: "Contents/MacOS/\(name)", kind: .copy(source)))
            }
        }
        // `<dll dir>/x86_64-unix/<name>.so` is where a PE module's unix half is looked for.
        entries.append(Entry(path: "Contents/MacOS/x86_64-unix", kind: .link(".")))
        for name in Self.names(in: lib.appending(path: "wine")) where name.hasSuffix("-windows") {
            entries.append(Entry(
                path: "Contents/MacOS/\(name)", kind: .link(lib.appending(path: "wine/\(name)").path)
            ))
        }
        // `ntdll.so` names `../external/libd3dshared.dylib` from its own directory.
        entries.append(Entry(path: "Contents/external", kind: .link(lib.appending(path: "external").path)))

        // The `.so` files name their dylibs `@loader_path/../../`, which from
        // `Contents/MacOS` is the top of the bundle.
        for name in Self.names(in: lib) where name.hasSuffix(".dylib") || name == "external" {
            entries.append(Entry(path: name, kind: .link(lib.appending(path: name).path)))
        }
        entries.append(Entry(path: "share", kind: .link(engine.appending(path: "share").path)))
        entries.append(Entry(path: "bin", kind: .link(engine.appending(path: "bin").path)))

        entries.append(Entry(path: "Contents/Info.plist", kind: .data(Data(infoPlist().utf8))))
        return entries
    }

    private func isCurrent(_ entries: [Entry]) -> Bool {
        let top = Set(entries.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
        let inMacOS = Set(entries.compactMap { entry -> String? in
            guard entry.path.hasPrefix("Contents/MacOS/") else { return nil }
            return String(entry.path.dropFirst("Contents/MacOS/".count))
        })
        // An entry the engine no longer has would otherwise survive every refresh.
        guard Set(Self.names(in: url)) == top,
              Set(Self.names(in: url.appending(path: "Contents/MacOS"))) == inMacOS
        else { return false }
        return entries.allSatisfy { $0.matches(in: url) }
    }

    private static func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// `LSUIElement` because every process of a prefix runs this executable: without it
    /// each one that touches the window server — `explorer.exe`, a CEF helper, Agent — is a
    /// Dock tile of its own. Wine makes a process a regular app when it shows a window, so
    /// the game still gets its tile.
    public func infoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>wine</string>
            <key>CFBundleIdentifier</key>
            <string>\(Self.bundleIdentifier)</string>
            <key>CFBundleName</key>
            <string>Sake Game</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>LSApplicationCategoryType</key>
            <string>public.app-category.games</string>
            <key>LSUIElement</key>
            <true/>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }

    struct Entry: Equatable {
        enum Kind: Equatable {
            case copy(URL)
            case link(String)
            case data(Data)
        }

        let path: String
        let kind: Kind

        func make(in root: URL) throws {
            let manager = FileManager.default
            let target = root.appending(path: path)
            try manager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            switch kind {
            case .copy(let source):
                try manager.copyItem(at: source, to: target)
            case .link(let destination):
                try manager.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            case .data(let data):
                try data.write(to: target)
            }
        }

        func matches(in root: URL) -> Bool {
            let manager = FileManager.default
            let target = root.appending(path: path)
            let link = try? manager.destinationOfSymbolicLink(atPath: target.path)
            switch kind {
            case .copy(let source):
                return link == nil && manager.contentsEqual(atPath: source.path, andPath: target.path)
            case .link(let destination):
                return link == destination
            case .data(let data):
                return link == nil && manager.contents(atPath: target.path) == data
            }
        }
    }
}
