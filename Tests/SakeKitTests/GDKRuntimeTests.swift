import Foundation
import Testing

@testable import SakeKit

private func temporaryRoot() -> Paths {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-runtime-\(UUID().uuidString)")
    return Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
}

private func remove(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
}

/// The runtime's real source and Makefile. The app runs that Makefile with variables of its
/// own choosing, so what is tested here is the Makefile the app will be handed.
private let repositoryRuntime = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "xgameruntime")

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
}

/// A compiler at the place the engine's toolchain unpacks to, which writes whatever `-o`
/// names -- the marker in it unless told otherwise -- and records how it was called.
private func makeCompiler(in paths: Paths, marker: Bool = true, failing: Bool = false) throws {
    let compiler = Component.llvmMinGW.unpackedURL(in: paths)
        .appending(path: "bin/\(GDKRuntimeBuilder.compilerName)")
    let content = marker ? "MZ \(GDKRuntime.marker)" : "MZ somebody else's"
    try write("""
        #!/bin/sh
        echo "$@" >> "$(dirname "$0")/cxx.args"
        \(failing ? "echo 'error: it did not compile' >&2; exit 1" : "")
        out=""
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "-o" ]; then out="$argument"; fi
            previous="$argument"
        done
        printf '%s' "\(content)" > "$out"
        """, to: compiler)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
}

private func compilerCalls(in paths: Paths) -> [String] {
    let file = Component.llvmMinGW.unpackedURL(in: paths).appending(path: "bin/cxx.args")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
}

/// The four files the Makefile compiles out of libHttpClient, and its licence.
private func makeLibHttpClient(in paths: Paths) throws -> URL {
    let tree = Component.libHttpClient.unpackedURL(in: paths)
    for name in ["AsyncLib", "TaskQueue", "ThreadPool_win32", "WaitTimer_win32"] {
        try write("// \(name)\n", to: tree.appending(path: "Source/Task/\(name).cpp"))
    }
    try write("// XAsync\n", to: tree.appending(path: "Include/XAsync.h"))
    try write("MIT License\n\nCopyright (c) 2017 Microsoft Corporation\n", to: tree.appending(path: "LICENSE.md"))
    return tree
}

private func builder(in paths: Paths, sources: URL? = repositoryRuntime) throws -> GDKRuntimeBuilder {
    let tree = Component.libHttpClient.unpackedURL(in: paths)
    return GDKRuntimeBuilder(
        paths: paths, sources: sources, runner: ProcessRunner(),
        libHttpClientContents: try #require(GDKRuntimeBuilder.contentsHash(of: tree))
    )
}

private func collect(_ stream: AsyncStream<GDKRuntimeEvent>) async -> [GDKRuntimeEvent] {
    var events: [GDKRuntimeEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func failure(in events: [GDKRuntimeEvent]) -> (reason: String, log: URL?)? {
    events.compactMap { event -> (String, URL?)? in
        if case .failed(let reason, let log) = event { (reason, log) } else { nil }
    }.first
}

@Test func theRealMakefileIsHandedTheEngineCompilerAndTheRuntimeLandsInTheEngine() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeCompiler(in: paths)
    let tree = try makeLibHttpClient(in: paths)
    let builder = try builder(in: paths)
    let runtime = GDKRuntime(paths: paths)

    #expect(!builder.isBuilt)
    // Nothing under the cache's build/ yet, as after somebody cleared it to free space.
    #expect(!FileManager.default.fileExists(atPath: paths.build.path))

    let events = await collect(builder.build())

    #expect(events.contains(.built), "\(events)")
    #expect(events.contains(.phase(.fetch)))
    #expect(GDKRuntime.carriesMarker(try Data(contentsOf: runtime.dll)))
    #expect(try Data(contentsOf: runtime.licence) == Data(contentsOf: tree.appending(path: "LICENSE.md")))
    #expect(builder.isBuilt)

    let calls = compilerCalls(in: paths)
    #expect(calls.contains { $0.contains("\(tree.path)/Source/Task/AsyncLib.cpp") })
    // Without it, the person's home would be in the DLL every bottle is given.
    #expect(calls.contains { $0.contains("-ffile-prefix-map=\(tree.path)=libHttpClient") })
    #expect(calls.contains { $0.contains("-o \(paths.gdkRuntimeBuild.path)/xgameruntime.dll") })
}

@Test func aCompileThatFailsNamesTheLogAndInstallsNothing() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeCompiler(in: paths, failing: true)
    _ = try makeLibHttpClient(in: paths)
    let builder = try builder(in: paths)

    let events = await collect(builder.build())

    #expect(failure(in: events)?.log == builder.logURL)
    #expect(try String(contentsOf: builder.logURL, encoding: .utf8).contains("it did not compile"))
    #expect(!FileManager.default.fileExists(atPath: GDKRuntime(paths: paths).dll.path))
}

@Test func aDllWithoutTheMarkerIsNeverInstalled() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeCompiler(in: paths, marker: false)
    _ = try makeLibHttpClient(in: paths)
    let builder = try builder(in: paths)

    let events = await collect(builder.build())

    // Placed, it would look like somebody else's and never be replaced.
    #expect(failure(in: events)?.reason.contains("never be updated") == true)
    #expect(!FileManager.default.fileExists(atPath: GDKRuntime(paths: paths).dll.path))
    #expect(!builder.isBuilt)
}

@Test func libHttpClientThatIsNotThePinnedSourceIsDeletedRatherThanBuilt() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeCompiler(in: paths)
    let tree = try makeLibHttpClient(in: paths)
    let builder = GDKRuntimeBuilder(
        paths: paths, sources: repositoryRuntime, runner: ProcessRunner(),
        libHttpClientContents: String(repeating: "0", count: 64)
    )

    let events = await collect(builder.build())

    #expect(failure(in: events)?.reason.contains("not the source sake pins") == true)
    #expect(!FileManager.default.fileExists(atPath: tree.path))
    #expect(compilerCalls(in: paths).isEmpty)
}

@Test func whatIsMissingIsNamedBeforeAnythingRuns() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }

    let noSource = GDKRuntimeBuilder(paths: paths, sources: nil)
    #expect(noSource.missingPrerequisite?.contains("carries no source") == true)

    let noCompiler = GDKRuntimeBuilder(paths: paths, sources: repositoryRuntime)
    #expect(noCompiler.missingPrerequisite?.contains("PE compiler") == true)

    let events = await collect(noCompiler.build())
    #expect(failure(in: events)?.reason.contains("PE compiler") == true)
    // Nothing ran, so there is no log to send anyone to.
    #expect(failure(in: events)?.log == nil)
}

@Test func aChangeToTheSourceSendsTheStepBackAndItsReadmeDoesNot() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let sources = paths.root.deletingLastPathComponent().appending(path: "xgameruntime")
    try write("all:\n", to: sources.appending(path: "Makefile"))
    try write("int main;\n", to: sources.appending(path: "src/main.cpp"))
    try write("# xgameruntime\n", to: sources.appending(path: "README.md"))
    let builder = GDKRuntimeBuilder(paths: paths, sources: sources)
    let runtime = GDKRuntime(paths: paths)

    try write("MZ \(GDKRuntime.marker)", to: runtime.dll)
    #expect(!builder.isBuilt)
    let stamp = try #require(builder.expectedStamp)
    try write("\(stamp)\n", to: paths.gdkRuntime.appending(path: "source.sha256"))
    #expect(builder.isBuilt)

    try write("# xgameruntime, reworded\n", to: sources.appending(path: "README.md"))
    try write("Finder was here", to: sources.appending(path: "src/.DS_Store"))
    #expect(builder.isBuilt)

    try write("int main = 1;\n", to: sources.appending(path: "src/main.cpp"))
    #expect(!builder.isBuilt)

    // With no source to compare with, a runtime that is there is the best there is.
    #expect(GDKRuntimeBuilder(paths: paths, sources: nil).isBuilt)
}

@Test func theMarkerIsTheOneEveryPlacedCopyCarries() throws {
    // Every copy already in a bottle carries this string, and one without it is taken for
    // somebody else's and never replaced. So it may never change, here and in main.cpp alike.
    #expect(GDKRuntime.marker == "sake's own xgameruntime.dll")

    let main = try String(contentsOf: repositoryRuntime.appending(path: "src/main.cpp"), encoding: .utf8)
    #expect(main.contains("\"\(GDKRuntime.marker)\""))
}

/// An engine with a runtime in it, and a bottle whose `system32` exists.
private func makeRuntimeAndBottle(_ paths: Paths) throws -> (GDKRuntime, Bottle) {
    let runtime = GDKRuntime(paths: paths)
    try write("MZ \(GDKRuntime.marker) today's", to: runtime.dll)
    try write("MIT License\n", to: runtime.licence)
    let bottle = Bottle(paths: paths)
    try FileManager.default.createDirectory(at: bottle.system32, withIntermediateDirectories: true)
    return (runtime, bottle)
}

@Test func aBottleIsGivenTheRuntimeAndItsLicenceOnceAndAfterThatNothing() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let (runtime, bottle) = try makeRuntimeAndBottle(paths)
    let placed = bottle.system32.appending(path: GDKRuntime.dllName)

    #expect(try runtime.place(in: bottle) == .placed)
    #expect(try Data(contentsOf: placed) == Data(contentsOf: runtime.dll))
    #expect(try Data(contentsOf: bottle.system32.appending(path: GDKRuntime.licenceName))
        == Data(contentsOf: runtime.licence))
    let names = try FileManager.default.contentsOfDirectory(atPath: bottle.system32.path)
    #expect(names.sorted() == [GDKRuntime.dllName, GDKRuntime.licenceName].sorted())

    #expect(try runtime.place(in: bottle) == .alreadyThere)
}

@Test func anOlderCopyOfSakesIsReplacedAndSomebodyElsesIsLeftAlone() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let (runtime, bottle) = try makeRuntimeAndBottle(paths)
    let placed = bottle.system32.appending(path: GDKRuntime.dllName)

    try write("MZ \(GDKRuntime.marker) yesterday's", to: placed)
    #expect(try runtime.place(in: bottle) == .replaced)
    #expect(try Data(contentsOf: placed) == Data(contentsOf: runtime.dll))

    try FileManager.default.removeItem(at: bottle.system32.appending(path: GDKRuntime.licenceName))
    try write("MZ a community stand-in", to: placed)
    #expect(try runtime.place(in: bottle) == .leftAlone)
    #expect(try String(contentsOf: placed, encoding: .utf8) == "MZ a community stand-in")
    #expect(!FileManager.default.fileExists(atPath: bottle.system32.appending(path: GDKRuntime.licenceName).path))
}

@Test func nothingIsPlacedWithoutARuntimeAndNoSystem32IsEverMade() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let bottle = Bottle(paths: paths)
    let runtime = GDKRuntime(paths: paths)

    try FileManager.default.createDirectory(at: bottle.system32, withIntermediateDirectories: true)
    #expect(try runtime.place(in: bottle) == .notBuilt)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bottle.system32.path).isEmpty)

    try write("MZ \(GDKRuntime.marker)", to: runtime.dll)
    let elsewhere = Bottle(paths: paths, name: "on a disk that is not plugged in")
    #expect(throws: GDKRuntimeError.self) { try runtime.place(in: elsewhere) }
    #expect(!FileManager.default.fileExists(atPath: elsewhere.url.path))
}
