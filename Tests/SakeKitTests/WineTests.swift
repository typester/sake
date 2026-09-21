import Foundation
import Testing

@testable import SakeKit

private func temporaryRoot() -> Paths {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-wine-\(UUID().uuidString)")
    return Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
}

private func remove(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
}

/// The real patches ship in the app bundle, and the tests are not an app, so the fake tree
/// gets a fake patch: what is being tested here is that the build applies what it is given
/// and stops when it cannot. ``PatchTests`` is where the real two are checked.
private func fakePatches(in paths: Paths) -> URL {
    paths.root.deletingLastPathComponent().appending(path: "patches")
}

private func builder(in paths: Paths) -> WineBuilder {
    WineBuilder(paths: paths, patcher: WinePatcher(directory: fakePatches(in: paths)))
}

private func configHeader(undefining: Set<String> = []) -> String {
    var lines = ["/* confdefs.h */", "#define PACKAGE_NAME \"Wine\""]
    for recipe in BuildRecipe.all {
        guard let macro = recipe.wineSoname else { continue }
        lines.append(
            undefining.contains(macro)
                ? "/* #undef \(macro) */"
                : "#define \(macro) \"\(recipe.installedName)\""
        )
    }
    return lines.joined(separator: "\n")
}

/// Everything ``WineBuilder`` expects to find: a finished engine prefix, an unpacked PE
/// toolchain, and a wine source whose out-of-tree `configure` writes the `include/config.h`
/// and `Makefile` a real one would.
private func makeFakeTree(
    in paths: Paths,
    undefining: Set<String> = [],
    glue: Bool = true
) throws {
    let manager = FileManager.default

    for recipe in BuildRecipe.all {
        let product = recipe.productURL(in: paths.engine)
        try manager.createDirectory(at: product.deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.createFile(atPath: product.path, contents: nil)
    }

    try manager.createDirectory(
        at: Component.llvmMinGW.unpackedURL(in: paths).appending(path: "bin"),
        withIntermediateDirectories: true
    )

    let source = Component.crossover.unpackedURL(in: paths)
    try manager.createDirectory(at: source, withIntermediateDirectories: true)
    try "Wine version 11.0\n".write(to: source.appending(path: "VERSION"), atomically: true, encoding: .utf8)

    let patched = source.appending(path: "dlls/ntdll/unix/loader.c")
    try manager.createDirectory(at: patched.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "one\ntwo\nthree\n".write(to: patched, atomically: true, encoding: .utf8)

    let patches = fakePatches(in: paths)
    try manager.createDirectory(at: patches, withIntermediateDirectories: true)
    try """
        Fake patch, so that the build has something to apply.

        --- a/dlls/ntdll/unix/loader.c
        +++ b/dlls/ntdll/unix/loader.c
        @@ -1,3 +1,4 @@
         one
         two
        +patched
         three

        """.write(to: patches.appending(path: "0001-fake.patch"), atomically: true, encoding: .utf8)

    // A real winemac.so has to be something `nm` can read, or the glue check cannot tell a
    // tree with D3DMetal from one without.
    let winemac = glue
        ? """
            \t@printf 'void d3dmetal_probe(void) {}\\n' > glue.c
            \t@clang -dynamiclib -o $$(cat prefix)/lib/wine/x86_64-unix/winemac.so glue.c
            """
        : "\t@echo not-a-library > $$(cat prefix)/lib/wine/x86_64-unix/winemac.so"

    let configure = """
        #!/bin/sh
        echo "$@" > configure.args
        printenv PATH > configure.path
        printenv CFLAGS > configure.cflags
        for a in "$@"; do
            case "$a" in --prefix=*) printf '%s' "${a#--prefix=}" > prefix ;; esac
        done
        mkdir -p include
        cat > include/config.h <<'HEADER'
        \(configHeader(undefining: undefining))
        HEADER
        cat > Makefile <<'MAKEFILE'
        all:
        \t@echo building wine
        install:
        \t@mkdir -p $$(cat prefix)/bin $$(cat prefix)/lib/wine/x86_64-unix
        \t@touch $$(cat prefix)/bin/wine
        \(winemac)
        \t@echo installing wine
        MAKEFILE
        echo "checking whether this is a fake... yes"
        """
    let url = source.appending(path: "configure")
    try configure.write(to: url, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func collect(_ stream: AsyncStream<WineEvent>) async -> [WineEvent] {
    var events: [WineEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func failure(in events: [WineEvent]) -> (reason: String, log: URL?)? {
    events.compactMap { event -> (String, URL?)? in
        if case .failed(let reason, let log) = event { (reason, log) } else { nil }
    }.first
}

@Test func theFlagsWineCannotBeBuiltWithoutAreAllThere() {
    let arguments = WineBuilder.configureArguments

    // 32-bit is not optional: Battle.net's launcher is 32-bit.
    #expect(arguments.contains("--enable-archs=i386,x86_64"))
    // The Command Line Tools cannot run their own compiler under `arch -x86_64`, so the
    // target has to be named out loud instead. See docs/wine-build.md.
    #expect(arguments.contains("--host=x86_64-apple-darwin"))
    #expect(arguments.contains("--build=x86_64-apple-darwin"))
    #expect(arguments.contains("CC=/usr/bin/clang -arch x86_64"))
    #expect(arguments.contains("CXX=/usr/bin/clang++ -arch x86_64"))
}

@Test func theFlagsThatWouldBreakItAreNotThere() {
    let arguments = WineBuilder.configureArguments

    // The first two do not compile at all; the third costs every game controller and the
    // fourth costs exception recovery, both silently. See docs/wine-build.md.
    for flag in ["--without-vulkan", "--without-gnutls", "--without-sdl", "--without-unwind"] {
        #expect(!arguments.contains(flag), "\(flag) is back")
    }
}

@Test func thePEToolchainLeadsTheSystemAndTheCompilerIsNamedAbsolutely() {
    let environment = WineBuilder.environment(
        prefix: URL(filePath: "/tmp/engine"),
        toolchain: URL(filePath: "/tmp/toolchain/bin"),
        inheriting: ["PATH": "/usr/bin:/bin"]
    )

    // These two are one decision. winebuild assembles every PE object with whatever plain
    // `clang` PATH offers, so llvm-mingw has to lead /usr/bin -- and llvm-mingw's clang
    // targets Windows, so configure has to be handed Apple's by absolute path instead.
    // Undo either half and the other breaks. See docs/wine-build.md.
    #expect(environment["PATH"] == "/tmp/engine/bin:/tmp/toolchain/bin:/usr/bin:/bin")
    #expect(WineBuilder.configureArguments.contains("CC=/usr/bin/clang -arch x86_64"))

    #expect(environment["CFLAGS"]?.contains("-Wno-implicit-function-declaration") == true)
    #expect(environment["CFLAGS"] == environment["CXXFLAGS"])
}

@Test func missingPrerequisitesAreNamedRatherThanRunInto() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }

    let builder = builder(in: paths)
    #expect(builder.missingPrerequisite?.contains("bison") == true)

    let events = await collect(builder.build())
    #expect(failure(in: events)?.reason.contains("bison") == true)
    // Nothing ran, so there is no log to send anyone to.
    #expect(failure(in: events)?.log == nil)
}

@Test func thePhasesRunInOrderAndTheVersionComesBack() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths)

    let builder = builder(in: paths)
    let events = await collect(builder.build())

    let phases = events.compactMap { event -> WinePhase? in
        if case .phase(let phase) = event { phase } else { nil }
    }
    #expect(phases == [.patch, .configure, .sonames, .make, .install, .verify])
    #expect(events.contains(.installed(version: "Wine version 11.0")))
    #expect(builder.isBuilt)
}

@Test func wineIsBuiltOutOfTreeSoTheOnlyCopyOfItsSourceStaysClean() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths)

    _ = await collect(builder(in: paths).build())

    let source = Component.crossover.unpackedURL(in: paths)
    #expect(!FileManager.default.fileExists(atPath: source.appending(path: "Makefile").path))
    #expect(FileManager.default.fileExists(atPath: paths.wineBuild.appending(path: "Makefile").path))
}

@Test func theToolchainAndThePrefixBothReachConfigure() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths)

    _ = await collect(builder(in: paths).build())

    let path = try String(contentsOf: paths.wineBuild.appending(path: "configure.path"), encoding: .utf8)
    let toolchain = Component.llvmMinGW.unpackedURL(in: paths).appending(path: "bin").path
    #expect(path.hasPrefix("\(paths.engine.appending(path: "bin").path):\(toolchain):"))
}

@Test func sonamesBecomeLoaderPathRelativeSoTheEngineCanMove() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths)

    _ = await collect(builder(in: paths).build())

    let header = try String(
        contentsOf: paths.wineBuild.appending(path: "include/config.h"), encoding: .utf8
    )
    #expect(header.contains("#define SONAME_LIBFREETYPE \"@loader_path/../../libfreetype.6.dylib\""))
    #expect(header.contains("#define SONAME_LIBGNUTLS \"@loader_path/../../libgnutls.30.dylib\""))
    #expect(header.contains("#define SONAME_LIBSDL2 \"@loader_path/../../libSDL2-2.0.0.dylib\""))
    #expect(header.contains("#define SONAME_LIBVULKAN \"@loader_path/../../libMoltenVK.dylib\""))
    // A leaf name only resolves through DYLD_LIBRARY_PATH, which does not reach Wine's
    // child processes. See docs/layout.md.
    #expect(!header.contains("\"libfreetype.6.dylib\""))
}

@Test func aLibraryConfigureDidNotFindStopsTheBuildAndIsNamed() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths, undefining: ["SONAME_LIBSDL2"])

    let builder = builder(in: paths)
    let events = await collect(builder.build())

    // Carrying on here is what "no game controller works, silently" looks like.
    #expect(failure(in: events)?.reason.contains("libSDL2-2.0.0.dylib") == true)
    #expect(failure(in: events)?.reason.contains("SONAME_LIBSDL2") == true)
    #expect(!builder.isBuilt)
}

@Test func aTreeWithoutTheD3DMetalGlueIsRejected() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths, glue: false)

    let events = await collect(builder(in: paths).build())

    #expect(failure(in: events)?.reason.contains("D3DMetal") == true)
    #expect(failure(in: events)?.log == builder(in: paths).logURL)
}

@Test func theWholeWineBuildGoesToALogEvenThoughTheUISeesLines() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths)

    let builder = builder(in: paths)
    let events = await collect(builder.build())

    let log = try String(contentsOf: builder.logURL, encoding: .utf8)
    #expect(log.contains("=== configure"))
    #expect(log.contains("checking whether this is a fake... yes"))
    #expect(log.contains("=== sonames SONAME_LIBSDL2 @loader_path/../../libSDL2-2.0.0.dylib"))
    #expect(log.contains("=== verify"))
    #expect(events.contains(.output("building wine")))
}

@Test func aWineThatIsAlreadyInstalledIsNotBuiltAgain() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths)

    let builder = builder(in: paths)
    _ = await collect(builder.build())
    let second = await collect(builder.build())

    #expect(second == [.alreadyBuilt, .finished])
}

@Test func wineIsPatchedBeforeItIsConfigured() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths)

    let builder = builder(in: paths)
    _ = await collect(builder.build())

    let source = Component.crossover.unpackedURL(in: paths)
    let patched = try String(
        contentsOf: source.appending(path: "dlls/ntdll/unix/loader.c"), encoding: .utf8
    )
    #expect(patched == "one\ntwo\npatched\nthree\n")
    #expect(try String(contentsOf: builder.logURL, encoding: .utf8).contains("applied: 0001-fake.patch"))
}

@Test func aBuildWithNoPatchesStopsBeforeConfigure() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    try makeFakeTree(in: paths)

    // A Wine built without them installs, passes every check here, and only fails at the
    // Play button, which is much too late to find out. See docs/runtime.md.
    let builder = WineBuilder(paths: paths, patcher: WinePatcher(directory: nil))
    let events = await collect(builder.build())

    #expect(failure(in: events) != nil)
    #expect(!FileManager.default.fileExists(atPath: paths.wineBuild.appending(path: "Makefile").path))
    #expect(!builder.isBuilt)
}

/// Wine's own tools, run in a bottle. The engine ships them as Windows programs under
/// `lib/wine/x86_64-windows/`, so what starts them is the bare name and nothing else.
@Test func eachWineToolIsStartedByItsBareNameInTheBottle() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-tool-\(UUID().uuidString)")
    let paths = Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
    defer { try? FileManager.default.removeItem(at: root) }

    let bottle = Bottle(paths: paths)
    #expect(WineTool.missingPrerequisite(in: bottle)?.contains("Wine is not built") == true)

    try FileManager.default.createDirectory(
        at: paths.engine.appending(path: "bin"), withIntermediateDirectories: true
    )
    try Data().write(to: paths.engine.appending(path: "bin/wine"))
    // Still no bottle, which is a different sentence from a missing engine.
    #expect(WineTool.missingPrerequisite(in: bottle)?.contains("no bottle") == true)

    // A bottle is its prefix, and what says the prefix is there is its registry.
    try FileManager.default.createDirectory(at: bottle.driveC, withIntermediateDirectories: true)
    try Data().write(to: bottle.systemRegistry)
    #expect(WineTool.missingPrerequisite(in: bottle) == nil)

    #expect(WineTool.allCases.map(\.rawValue) == ["winecfg", "regedit", "uninstaller", "taskmgr"])
    for tool in WineTool.allCases {
        let command = tool.command(in: bottle)
        #expect(command.executable.lastPathComponent == "wine")
        #expect(command.arguments == [tool.rawValue])
        #expect(command.environment?["WINEPREFIX"] == bottle.url.path)
        #expect(command.workingDirectory?.lastPathComponent == "drive_c")
        // `arch` would strip every DYLD_* variable, and wine is x86_64 already.
        #expect(command.architecture == .native)
        #expect(tool.logURL(in: paths).lastPathComponent == "tool-\(tool.rawValue).log")
    }
}
