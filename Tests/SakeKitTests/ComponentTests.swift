import Foundation
import Testing

@testable import SakeKit

@Test func everyComponentIsDistinctAndFetchedOverHTTPS() {
    let all = Component.all

    #expect(Set(all.map(\.id)).count == all.count)
    #expect(Set(all.map(\.fileName)).count == all.count)
    for component in all {
        #expect(component.url.scheme == "https", "\(component.id) is not fetched over https")
        #expect(!component.version.isEmpty)
        #expect(!component.unpacked.isEmpty)
    }
}

@Test func hashesArePinnedExceptWhereNoCopyWasAvailableToHash() {
    let unpinned = Component.all.filter { $0.sha256 == nil }.map(\.id)

    #expect(unpinned == ["crossover"])
    for component in Component.all where component.sha256 != nil {
        #expect(component.sha256?.count == 64)
    }
}

@Test func libHttpClientIsFetchedByCommitAndNoPartOfTheSourcesStep() {
    let commit = "7ead73f6389271c2dc2cb10cdafcc587b899bd8a"
    let libHttpClient = Component.libHttpClient

    #expect(libHttpClient.url.path.contains(commit))
    #expect(libHttpClient.unpacked == "libHttpClient-\(commit)")
    // GitHub promises the files inside an archive of a commit and not its bytes, so it is
    // the files that are checked, and a hash of the archive would only be a way to fail.
    #expect(libHttpClient.sha256 == nil)
    #expect(!Component.all.contains(libHttpClient))
}

@Test func theFileNameCarriesTheVersionSoARaiseCannotHitAStaleDownload() {
    let bison = Component.all.first { $0.id == "bison" }

    #expect(bison?.fileName == "bison-3.8.2.tar.xz")
}

@Test func crossoverUnpacksIntoTheCacheRootBecauseItsPathsStartWithSources() {
    let paths = Paths(root: URL(filePath: "/tmp/s"), cache: URL(filePath: "/tmp/c"))
    let crossover = Component.all.first { $0.id == "crossover" }!

    #expect(crossover.destinationURL(in: paths).path == "/tmp/c")
    #expect(crossover.unpackedURL(in: paths).path == "/tmp/c/sources/wine")
    #expect(crossover.members == ["sources/wine"])
}

@Test func theToolchainDoesNotLandWithTheSources() {
    let paths = Paths(root: URL(filePath: "/tmp/s"), cache: URL(filePath: "/tmp/c"))
    let mingw = Component.all.first { $0.id == "llvm-mingw" }!

    #expect(mingw.unpackedURL(in: paths).path
            == "/tmp/c/toolchain/llvm-mingw-20260908-ucrt-macos-universal")
    #expect(mingw.archiveURL(in: paths).path == "/tmp/c/dl/llvm-mingw-20260908.tar.xz")
}

@Test func whatIsOnDiskIsWhatCountsAsPresent() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-present-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root.appending(path: "engine-root"), cache: root.appending(path: "cache"))
    let gmp = Component.all.first { $0.id == "gmp" }!
    let recipe = BuildRecipe.all.first { $0.componentID == "gmp" }!
    let prefix = paths.engine

    #expect(!gmp.isUnpacked(in: paths))
    #expect(!recipe.isBuilt(in: prefix))

    try FileManager.default.createDirectory(at: gmp.unpackedURL(in: paths), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: recipe.productURL(in: prefix).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: recipe.productURL(in: prefix))

    #expect(gmp.isUnpacked(in: paths))
    #expect(recipe.isBuilt(in: prefix))
}
