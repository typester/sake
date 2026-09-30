import Foundation
import Testing

@testable import SakeKit

/// The repository's own `patches/`. The app finds them in its bundle, which a test bundle
/// is not, so they are found from this file instead.
private let repositoryPatches = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "patches")

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "sake-patch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A tree with one file in it, and a patch that changes that file.
private func makeTree(in root: URL, content: String = "one\ntwo\nthree\n") throws -> (tree: URL, patches: URL) {
    let tree = root.appending(path: "tree")
    let file = tree.appending(path: "dlls/ntdll/unix/loader.c")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: file, atomically: true, encoding: .utf8)

    let patches = root.appending(path: "patches")
    try FileManager.default.createDirectory(at: patches, withIntermediateDirectories: true)
    try """
        Say what it does here, the way the real ones do.

        --- a/dlls/ntdll/unix/loader.c
        +++ b/dlls/ntdll/unix/loader.c
        @@ -1,3 +1,4 @@
         one
         two
        +patched
         three

        """.write(to: patches.appending(path: "0001-fake.patch"), atomically: true, encoding: .utf8)

    return (tree, patches)
}

/// Three patches that change the same lines of one file, so that once B is in, A neither
/// reverses on its own nor applies again -- the shape that stopped the second real build on
/// 2026-09-20. B renames the line A inserted and every context line A relies on, so no fuzz
/// factor lets `patch` find A's hunk after B.
private enum Stack {
    static let file = "dlls/ntdll/unix/loader.c"
    static let pristine = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n"
    static let afterA = "one\ntwo\nthree\nfour\nalpha\nfive\nsix\nseven\n"
    static let afterB = "one\ntwo\ntrois\nquatre\nalfa\ncinq\nsechs\nseven\n"
    static let afterC = "one\ntwo\ntrois\nquatre\nalfa\ncinq\nsechs\nseven\ngamma\n"

    static let a = """
        Insert alpha after four.

        --- a/dlls/ntdll/unix/loader.c
        +++ b/dlls/ntdll/unix/loader.c
        @@ -2,6 +2,7 @@
         two
         three
         four
        +alpha
         five
         six
         seven

        """
    static let b = """
        Rename alpha and the lines around it, so that A no longer reverses on its own.

        --- a/dlls/ntdll/unix/loader.c
        +++ b/dlls/ntdll/unix/loader.c
        @@ -1,8 +1,8 @@
         one
         two
        -three
        -four
        -alpha
        -five
        -six
        +trois
        +quatre
        +alfa
        +cinq
        +sechs
         seven

        """
    static let c = """
        Add gamma at the end.

        --- a/dlls/ntdll/unix/loader.c
        +++ b/dlls/ntdll/unix/loader.c
        @@ -6,3 +6,4 @@
         cinq
         sechs
         seven
        +gamma

        """

    /// A tree whose file already holds `content`, and a `patches/` holding `patches` in order.
    static func make(in root: URL, content: String, patches: [(name: String, text: String)]) throws -> (tree: URL, patches: URL) {
        let tree = root.appending(path: "tree")
        let file = tree.appending(path: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)

        let directory = root.appending(path: "patches")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for patch in patches {
            try patch.text.write(to: directory.appending(path: patch.name), atomically: true, encoding: .utf8)
        }
        return (tree, directory)
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }
}

private func read(_ tree: URL) throws -> String {
    try String(contentsOf: tree.appending(path: "dlls/ntdll/unix/loader.c"), encoding: .utf8)
}

@Test func theRepositoryCarriesTheSevenPatchesAndSaysTheyAreNotMIT() throws {
    let patcher = WinePatcher(directory: repositoryPatches)
    let patches = try patcher.patches()

    #expect(patches.map(\.id) == [
        "0001-ntdll-libd3dshared-fallback.patch",
        "0002-ntdll-read-BOOLEAN-syscall-arguments-as-the-Windows-ABI-defines-them.patch",
        "0003-winemac-factor-out-MetalViewSwapChain.patch",
        "0004-winemac-cross-process-MetalViewSwapChain-via-CALayerHost.patch",
        "0005-winemac-cross-process-child-window-swapchains.patch",
        "0006-winemac-give-D3DMetal-a-hosted-swapchain-for-a-window-it-does-not-own.patch",
        "0007-ntdll-start-each-program-from-a-game-bundle-named-after-it.patch",
    ])
    // Each one says what it does on its first line, which is where the reasoning starts,
    // and names the module it changes the way a Wine commit does.
    for patch in patches {
        let subject = patch.subject
        #expect(
            subject.hasPrefix("ntdll: ") || subject.hasPrefix("winemac: "),
            "\(patch.id): \(subject)"
        )
    }

    // A patch against Wine is a derivative of Wine, whatever this repository's own licence
    // says. See docs/licensing.md.
    let licence = try String(contentsOf: repositoryPatches.appending(path: "LICENSE"), encoding: .utf8)
    #expect(licence.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
    #expect(licence.contains("Version 2.1"))
}

@Test func nothingOutsideNtdllAndTheMacDriverIsPatched() throws {
    for patch in try WinePatcher(directory: repositoryPatches).patches() {
        let targets = patch.targets

        #expect(!targets.isEmpty, "\(patch.id) patches nothing")
        for target in targets {
            // Widened from ntdll alone on 2026-09-20, as a decision: Steam's client draws
            // in one process and owns its window in another, and the driver that has to
            // carry that across is winemac.drv. docs/runtime.md has the measurement.
            #expect(
                target.hasPrefix("dlls/ntdll/") || target.hasPrefix("dlls/winemac.drv/"),
                "\(patch.id) reaches \(target)"
            )
        }
    }
}

@Test func aPatchIsAppliedOnceAndThenRecognisedAsAlreadyIn() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tree, patches) = try makeTree(in: root)
    let patcher = WinePatcher(directory: patches)

    let first = Lines()
    try await patcher.apply(to: tree) { first.append($0) }
    #expect(first.all == ["applied: 0001-fake.patch"])
    #expect(try read(tree) == "one\ntwo\npatched\nthree\n")

    // The source tree is unpacked once and never re-extracted, so every later build finds
    // the patches already in. Asking `patch` beats a marker file, which would have to be
    // invalidated by hand whenever a patch here changed.
    let second = Lines()
    try await patcher.apply(to: tree) { second.append($0) }
    #expect(second.all == ["already applied: 0001-fake.patch"])
    #expect(try read(tree) == "one\ntwo\npatched\nthree\n")
}

@Test func aPatchThatFitsNeitherFormIsAnErrorAndLeavesTheTreeAlone() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tree, patches) = try makeTree(in: root, content: "something\nelse\nentirely\n")

    await #expect(throws: PatchError.doesNotApply(patch: "0001-fake.patch", tree: tree.path)) {
        try await WinePatcher(directory: patches).apply(to: tree)
    }
    #expect(try read(tree) == "something\nelse\nentirely\n")
}

@Test func aStackOnOneFileIsRecognisedOnTheSecondRun() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tree, patches) = try Stack.make(in: root, content: Stack.afterB, patches: [
        ("0001-a.patch", Stack.a), ("0002-b.patch", Stack.b),
    ])

    // A on its own reverses on nothing here and applies to nothing here: the second real
    // build on 2026-09-20 stopped exactly there. The stack A, B reverses top-down.
    let lines = Lines()
    try await WinePatcher(directory: patches).apply(to: tree) { lines.append($0) }
    #expect(lines.all == [
        "already applied: 0001-a.patch (under later patches)",
        "already applied: 0002-b.patch",
    ])
    #expect(try read(tree) == Stack.afterB)
}

@Test func anOlderTreeWithOnlyTheFirstPatchInGetsTheRestApplied() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tree, patches) = try Stack.make(in: root, content: Stack.afterA, patches: [
        ("0001-a.patch", Stack.a), ("0002-b.patch", Stack.b),
    ])

    // An engine built by an older sake has the patches that sake carried and none of the
    // ones added since.
    let lines = Lines()
    try await WinePatcher(directory: patches).apply(to: tree) { lines.append($0) }
    #expect(lines.all == ["already applied: 0001-a.patch", "applied: 0002-b.patch"])
    #expect(try read(tree) == Stack.afterB)
}

@Test func aNewPatchGoesOnTopOfAnAppliedStack() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tree, patches) = try Stack.make(in: root, content: Stack.afterB, patches: [
        ("0001-a.patch", Stack.a), ("0002-b.patch", Stack.b), ("0003-c.patch", Stack.c),
    ])

    let lines = Lines()
    try await WinePatcher(directory: patches).apply(to: tree) { lines.append($0) }
    #expect(lines.all == [
        "already applied: 0001-a.patch (under later patches)",
        "already applied: 0002-b.patch",
        "applied: 0003-c.patch",
    ])
    #expect(try read(tree) == Stack.afterC)
}

@Test func aStackThatDoesNotReverseIsStillAnErrorAndLeavesTheTreeAlone() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // Almost B's result, but the line A inserted and B renamed reads beta: B does not reverse
    // on this, so no run from A reverses either, and A is the error the way it always was.
    let content = "one\ntwo\ntrois\nquatre\nbeta\ncinq\nsechs\nseven\n"
    let (tree, patches) = try Stack.make(in: root, content: content, patches: [
        ("0001-a.patch", Stack.a), ("0002-b.patch", Stack.b), ("0003-c.patch", Stack.c),
    ])

    await #expect(throws: PatchError.doesNotApply(patch: "0001-a.patch", tree: tree.path)) {
        try await WinePatcher(directory: patches).apply(to: tree)
    }
    #expect(try read(tree) == content)
}

@Test func noPatchesAtAllIsAFailureRatherThanAQuietSuccess() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tree, patches) = try makeTree(in: root)
    try FileManager.default.removeItem(at: patches.appending(path: "0001-fake.patch"))

    // Wine builds, installs and passes every check this repository makes without them.
    // What it cannot do is start a game, which is a long way from here.
    await #expect(throws: PatchError.noPatches(directory: patches.path)) {
        try await WinePatcher(directory: patches).apply(to: tree)
    }
    await #expect(throws: PatchError.directoryMissing) {
        try await WinePatcher(directory: nil).apply(to: tree)
    }
}
