import Foundation

public struct Component: Sendable, Identifiable, Equatable {
    public enum Archive: String, Sendable {
        case tar
        case tarGz = "tar.gz"
        case tarXz = "tar.xz"
    }

    public enum Destination: Sendable {
        case sources
        case toolchain

        /// The cache root. CrossOver's tarball has `sources/` inside it already, so
        /// unpacking it under `sources/` would produce `sources/sources/wine`.
        case cacheRoot
    }

    public let id: String
    public let version: String
    public let url: URL

    /// `nil` where there is no known-good hash to compare against. CrossOver's tarball is
    /// the standing case — no copy of it survived in the prototype to hash — and any
    /// version the user picks that nobody has hashed lands here too. libHttpClient is `nil`
    /// for another reason: what it unpacks to is checked instead, by ``GDKRuntimeBuilder``.
    public let sha256: String?

    public let archive: Archive
    public let destination: Destination

    /// The unpacked tree, relative to `destination`. Its presence is what says the
    /// component is already in place.
    public let unpacked: String

    /// Members to extract, or empty for the whole archive.
    public let members: [String]

    /// Deliberately not the name the server uses: a versioned name means raising a version
    /// cannot collide with a stale download of the old one.
    public var fileName: String { "\(id)-\(version).\(archive.rawValue)" }

    public func archiveURL(in paths: Paths) -> URL {
        paths.downloads.appending(path: fileName)
    }

    public func destinationURL(in paths: Paths) -> URL {
        switch destination {
        case .sources: paths.sources
        case .toolchain: paths.toolchain
        case .cacheRoot: paths.cache
        }
    }

    public func unpackedURL(in paths: Paths) -> URL {
        destinationURL(in: paths).appending(path: unpacked)
    }

    public func isUnpacked(in paths: Paths) -> Bool {
        FileManager.default.fileExists(atPath: unpackedURL(in: paths).path)
    }
}

extension Component {
    /// What the build needs, in the order it needs them. `docs/wine-build.md` says why each
    /// one is here and what breaks without it; this list carries only versions and sources.
    ///
    /// The hashes are of the files the d4-mac prototype downloaded on 2026-09-17 and built
    /// a working Wine from, hashed 2026-09-19. bison's and gmp's match the sums upstream
    /// publishes for those releases.
    public static let all: [Component] = [
        Component(
            id: "llvm-mingw",
            version: "20260908",
            url: URL(string: "https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/llvm-mingw-20260908-ucrt-macos-universal.tar.xz")!,
            sha256: "d1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149",
            archive: .tarXz,
            destination: .toolchain,
            unpacked: "llvm-mingw-20260908-ucrt-macos-universal",
            members: []
        ),
        Component(
            id: "bison",
            version: "3.8.2",
            url: URL(string: "https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz")!,
            sha256: "9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2",
            archive: .tarXz,
            destination: .sources,
            unpacked: "bison-3.8.2",
            members: []
        ),
        Component(
            id: "pkgconf",
            version: "2.3.0",
            url: URL(string: "https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz")!,
            sha256: "3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b",
            archive: .tarXz,
            destination: .sources,
            unpacked: "pkgconf-2.3.0",
            members: []
        ),
        Component(
            id: "gmp",
            version: "6.3.0",
            url: URL(string: "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz")!,
            sha256: "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898",
            archive: .tarXz,
            destination: .sources,
            unpacked: "gmp-6.3.0",
            members: []
        ),
        Component(
            id: "nettle",
            version: "3.10.1",
            url: URL(string: "https://ftp.gnu.org/gnu/nettle/nettle-3.10.1.tar.gz")!,
            sha256: "b0fcdd7fc0cdea6e80dcf1dd85ba794af0d5b4a57e26397eee3bc193272d9132",
            archive: .tarGz,
            destination: .sources,
            unpacked: "nettle-3.10.1",
            members: []
        ),
        Component(
            id: "libtasn1",
            version: "4.20.0",
            url: URL(string: "https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz")!,
            sha256: "92e0e3bd4c02d4aeee76036b2ddd83f0c732ba4cda5cb71d583272b23587a76c",
            archive: .tarGz,
            destination: .sources,
            unpacked: "libtasn1-4.20.0",
            members: []
        ),
        Component(
            id: "gnutls",
            version: "3.8.10",
            url: URL(string: "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.10.tar.xz")!,
            sha256: "db7fab7cce791e7727ebbef2334301c821d79a550ec55c9ef096b610b03eb6b7",
            archive: .tarXz,
            destination: .sources,
            unpacked: "gnutls-3.8.10",
            members: []
        ),
        Component(
            id: "freetype",
            version: "2.13.3",
            url: URL(string: "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz")!,
            sha256: "0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289",
            archive: .tarXz,
            destination: .sources,
            unpacked: "freetype-2.13.3",
            members: []
        ),
        Component(
            id: "sdl2",
            version: "2.32.10",
            url: URL(string: "https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz")!,
            sha256: "5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165",
            archive: .tarGz,
            destination: .sources,
            unpacked: "SDL2-2.32.10",
            members: []
        ),
        Component(
            id: "moltenvk",
            version: "1.4.2",
            url: URL(string: "https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar")!,
            sha256: "f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e",
            archive: .tar,
            destination: .sources,
            unpacked: "MoltenVK",
            members: []
        ),
        Component(
            id: "crossover",
            version: "26.3.0",
            url: URL(string: "https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz")!,
            sha256: nil,
            archive: .tarGz,
            destination: .cacheRoot,
            unpacked: "sources/wine",
            members: ["sources/wine"]
        ),
    ]
}

extension Component {
    /// CrossOver's source drop: the tree Wine itself is built from.
    public static var crossover: Component { named("crossover") }

    /// The PE compiler, which Wine's configure finds under its `x86_64-w64-mingw32-gcc`
    /// name -- a symlink to a clang wrapper, so mingw-w64's own GCC is never needed.
    public static var llvmMinGW: Component { named("llvm-mingw") }

    /// Microsoft's task queue and `XAsync`, compiled into sake's GDK runtime.
    ///
    /// Not in ``all``: the GDK Runtime step fetches it, so the rest of setup never waits on
    /// it. GitHub promises the files inside an archive of a commit and not the bytes of the
    /// archive, so it is pinned by what it unpacks to. See docs/gdk.md.
    public static let libHttpClient = Component(
        id: "libhttpclient",
        version: "7ead73f6",
        url: URL(string: "https://github.com/microsoft/libHttpClient/archive/7ead73f6389271c2dc2cb10cdafcc587b899bd8a.tar.gz")!,
        sha256: nil,
        archive: .tarGz,
        destination: .sources,
        unpacked: "libHttpClient-7ead73f6389271c2dc2cb10cdafcc587b899bd8a",
        members: []
    )
}
