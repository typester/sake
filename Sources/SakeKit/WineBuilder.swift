import Foundation

public enum WinePhase: String, Sendable {
    case unpack
    case patch
    case configure
    case sonames
    case headers
    case make
    case install
    case verify
}

public enum WineEvent: Sendable, Equatable {
    case alreadyBuilt
    case started
    case phase(WinePhase)
    case output(String)
    case installed(version: String)
    case failed(reason: String, log: URL?)
    case finished
}

public enum WineError: Error, Equatable, LocalizedError {
    case notReady(String)
    case phaseFailed(phase: String, status: Int32, log: String)
    case sonameUndefined(macro: String, library: String)
    case sonameUnresolved(macro: String, soname: String, from: String)
    case glueMissing(at: String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let what):
            what
        case .phaseFailed(let phase, let status, let log):
            "Wine failed during \(phase) (exit \(status)). The full output is in \(log)."
        case .sonameUndefined(let macro, let library):
            """
            Wine's configure did not find \(library), so \(macro) is undefined and Wine \
            would silently do without it. Check that the engine has the library and that \
            pkg-config can see it.
            """
        case .sonameUnresolved(let macro, let soname, let from):
            "\(macro) is \(soname), which resolves to nothing from \(from)."
        case .glueMissing(let at):
            """
            \(at) has no D3DMetal symbols, so this is not CrossOver's Wine. Upstream Wine \
            builds perfectly and cannot run DirectX 12.
            """
        }
    }

    /// A missing prerequisite is caught before anything runs, so there is no log to point at.
    var cameFromARun: Bool {
        if case .notReady = self { false } else { true }
    }
}

/// Builds CrossOver's Wine against the engine the ``PrefixBuilder`` produced.
///
/// Its own type rather than another ``BuildRecipe``: this builds out of tree, edits what
/// configure wrote before compiling it, and checks the result is the tree it asked for.
public struct WineBuilder: Sendable {
    private let paths: Paths
    private let runner: ProcessRunner
    private let patcher: WinePatcher
    private let unpacker: Unpacker

    public init(
        paths: Paths = .default,
        runner: ProcessRunner = ProcessRunner(),
        patcher: WinePatcher = WinePatcher(),
        unpacker: Unpacker = Unpacker()
    ) {
        self.paths = paths
        self.runner = runner
        self.patcher = patcher
        self.unpacker = unpacker
    }

    public var prefix: URL { paths.engine }

    public var logURL: URL { paths.build.appending(path: "wine.log") }

    var stampURL: URL { prefix.appending(path: "lib/wine/sake-patches.sha256") }

    /// Built, and from the patches this copy of sake carries. Without patches to compare
    /// with, an engine that is there counts.
    public var isBuilt: Bool { hasWine && !isOutdated }

    /// Built, but from other patches, or by a sake that kept no record of them. See
    /// docs/wine-build.md.
    public var isOutdated: Bool {
        guard hasWine, let expected = expectedPatches else { return false }
        return recordedPatches != expected
    }

    /// Why the step has to be done again, when it does.
    public var outdatedReason: String? {
        guard isOutdated else { return nil }
        let which = recordedPatches == nil
            ? "This engine was built by an earlier sake and may lack patches this one carries."
            : "This engine was built from other patches than this copy of sake carries."
        return which + " Building it again takes as long as the first build, and D3DMetal goes back in afterwards with one press."
    }

    private var hasWine: Bool {
        FileManager.default.fileExists(atPath: prefix.appending(path: "bin/wine").path)
    }

    private var recordedPatches: String? {
        (try? String(contentsOf: stampURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The patches inside the app are hashed once per process: the wizard asks every step's
    /// state many times each time it draws.
    private var expectedPatches: String? {
        patcher.directory == WinePatcher.bundled ? Self.bundledPatches : patcher.fingerprint()
    }

    private static let bundledPatches: String? = WinePatcher().fingerprint()

    /// What has to exist before this can start, as a sentence, or `nil` when it can.
    public var missingPrerequisite: String? {
        if let recipe = BuildRecipe.all.first(where: { !$0.isBuilt(in: prefix) }) {
            return "The engine has no \(recipe.componentID) yet. Build the prefix first."
        }
        if !Component.crossover.isUnpacked(in: paths) {
            return "CrossOver's sources are not unpacked yet. Download the sources first."
        }
        if !Component.llvmMinGW.isUnpacked(in: paths) {
            return "The PE compiler is not unpacked yet. Download the sources first."
        }
        return nil
    }

    /// From ``Paths/wineUnixLibraries`` back up to the engine's `lib`. `PathsTests` pins the
    /// two together, so a change to either fails there rather than at runtime.
    static let engineLibrariesFromWineUnix = "../.."

    /// clang 16+ turned several legacy-C patterns into hard errors. Apple's own formula
    /// carried the same list.
    static let compilerFlags = """
        -O2 -Wno-implicit-function-declaration -Wno-format -Wno-deprecated-declarations \
        -Wno-incompatible-pointer-types
        """

    /// The prototype's flags, plus the triplet sake needs because it cannot wrap the build
    /// in `arch -x86_64`. What matters as much is what is *not* here: `--without-vulkan`
    /// and `--without-gnutls` do not compile, `--without-sdl` costs every game controller,
    /// and `--without-unwind` costs exception recovery. See docs/wine-build.md.
    static let configureArguments: [String] = [
        "--host=x86_64-apple-darwin",
        "--build=x86_64-apple-darwin",
        // Absolute, because llvm-mingw leads /usr/bin and ships a bare `clang` of its own.
        // `environment` below says why it has to lead, and why that forces this.
        "CC=/usr/bin/clang -arch x86_64",
        "CXX=/usr/bin/clang++ -arch x86_64",
        "--enable-win64",
        // Battle.net's launcher is 32-bit, so 32-bit support is not optional.
        "--enable-archs=i386,x86_64",
        "--disable-tests",
        "--without-x",
        "--with-freetype", "--with-gnutls", "--with-vulkan",
        "--without-gstreamer", "--without-fontconfig", "--without-cups", "--without-sane",
        "--without-gphoto", "--without-pulse", "--without-alsa", "--without-oss",
        "--without-dbus", "--without-inotify", "--without-udev", "--without-krb5",
        "--without-gssapi", "--without-netapi", "--without-pcap", "--without-pcsclite",
        "--without-usb", "--without-v4l2", "--without-hwloc", "--without-ffmpeg",
        "--without-opencl", "--without-capi",
    ]

    public static func environment(
        prefix: URL,
        toolchain: URL,
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // The PE compiler goes AHEAD of /usr/bin, and `CC` is absolute. Both halves are
        // load-bearing and they pull opposite ways: winebuild assembles every PE object
        // with whatever plain `clang` PATH offers it, so it needs llvm-mingw's in front,
        // while configure needs Apple's -- llvm-mingw's targets Windows and cannot link a
        // macOS executable at all. Naming CC absolutely keeps configure out of the fight.
        // Measured in sake on 2026-09-19; see docs/wine-build.md.
        var environment = PrefixBuilder.environment(
            prefix: prefix, alsoOnPath: [toolchain], inheriting: base
        )
        environment["CFLAGS"] = compilerFlags
        environment["CXXFLAGS"] = compilerFlags
        return environment
    }

    public func build() -> AsyncStream<WineEvent> {
        AsyncStream { continuation in
            let work = Task {
                if isBuilt {
                    continuation.yield(.alreadyBuilt)
                } else {
                    continuation.yield(.started)
                    do {
                        try await run { continuation.yield(.phase($0)) } onOutput: {
                            continuation.yield(.output($0))
                        }
                        continuation.yield(.installed(version: installedVersion()))
                    } catch {
                        if !Task.isCancelled {
                            continuation.yield(.failed(
                                reason: error.localizedDescription,
                                log: logToOffer(after: error)
                            ))
                        }
                    }
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Offering the log is only useful when something wrote to it. A missing prerequisite
    /// and a patch that will not apply both say everything they have in the message itself.
    private func logToOffer(after error: Error) -> URL? {
        if let wine = error as? WineError, !wine.cameFromARun { return nil }
        if error is PatchError { return nil }
        return logURL
    }

    private func run(
        onPhase: @Sendable (WinePhase) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        if let missing = missingPrerequisite { throw WineError.notReady(missing) }

        let source = Component.crossover.unpackedURL(in: paths)
        try FileManager.default.createDirectory(at: paths.wineBuild, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let log = try LogFile(at: logURL)
        defer { log.close() }

        let environment = Self.environment(
            prefix: prefix,
            toolchain: Component.llvmMinGW.unpackedURL(in: paths).appending(path: "bin")
        )
        let make = URL(filePath: "/usr/bin/make")
        let jobs = ProcessInfo.processInfo.activeProcessorCount

        // Only a step that is not done gets here, so an engine that is there is one from
        // other patches.
        if hasWine {
            onPhase(.unpack)
            try await unpackAgain(source, log: log, onOutput: onOutput)
        }

        onPhase(.patch)
        try await patcher.apply(to: source) { line in
            log.write(line + "\n")
            onOutput(line)
        }

        onPhase(.configure)
        try await runPhase(
            .configure,
            source.appending(path: "configure"),
            ["--prefix=\(prefix.path)"] + Self.configureArguments,
            environment: environment, log: log, onOutput: onOutput
        )

        onPhase(.sonames)
        try pinSonames(log: log)

        // A make of its own, before anything is compiled: makedep does not follow
        // `#include "x.idl"` when it works out what a generated header includes, so some
        // objects miss a dependency on headers theirs include -- actxprxy_mshtml_p.o on
        // include/exdisp.h -- and -j can compile one first. Every header it misses is in
        // include/. See docs/wine-build.md.
        onPhase(.headers)
        try await runPhase(
            .headers, make, ["-j\(jobs)", "include/all"],
            environment: environment, log: log, onOutput: onOutput
        )

        onPhase(.make)
        try await runPhase(.make, make, ["-j\(jobs)"], environment: environment, log: log, onOutput: onOutput)

        onPhase(.install)
        try await runPhase(.install, make, ["install"], environment: environment, log: log, onOutput: onOutput)

        onPhase(.verify)
        try await verify(log: log)

        // Last, so that a build stopped part way does not count as one from these patches.
        if let expected = expectedPatches {
            try Data("\(expected)\n".utf8).write(to: stampURL, options: .atomic)
            log.write("=== record \(stampURL.path)\n")
        }
    }

    /// Back to CrossOver's own tree: a patch that changed or went cannot be taken off a tree
    /// that has it. With no archive to start from, the tree is patched as it is, which is
    /// enough for a patch that was only added.
    private func unpackAgain(
        _ source: URL,
        log: LogFile,
        onOutput: @Sendable (String) -> Void
    ) async throws {
        let component = Component.crossover
        let archive = component.archiveURL(in: paths)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            log.write("=== unpack no \(archive.path), so the tree is patched as it is\n")
            return
        }
        log.write("=== unpack \(archive.path)\n")
        onOutput("unpacking \(archive.lastPathComponent)")
        try FileManager.default.removeItem(at: source)
        try await unpacker.unpack(archive, into: component.destinationURL(in: paths), members: component.members)
    }

    private func runPhase(
        _ phase: WinePhase,
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        log: LogFile,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        log.write("=== \(phase.rawValue) \(executable.path) \(arguments.joined(separator: " "))\n")

        let result = try await runner.run(
            Command(
                executable: executable,
                arguments: arguments,
                environment: environment,
                // Out of tree, which leaves the unpacked source as it came out of the
                // tarball -- the only copy sake has of it.
                workingDirectory: paths.wineBuild,
                // Never translated. The Command Line Tools cannot run their own compiler
                // under `arch -x86_64` at all, which is how the prototype got x86_64 host
                // tools; the triplet and CC above say it instead. See docs/wine-build.md.
                architecture: .native
            )
        ) { line in
            log.write(line.text + "\n")
            onOutput(line.text)
        }

        guard result.succeeded else {
            throw WineError.phaseFailed(
                phase: phase.rawValue, status: result.exitStatus, log: logURL.path
            )
        }
    }

    /// Rewrite the sonames configure recorded as leaf names, which only resolve through
    /// `DYLD_LIBRARY_PATH` -- and that does not reach Wine's child processes, so the main
    /// process finds freetype while every CEF subprocess reports it cannot. Relative to
    /// `@loader_path` rather than absolute, so the built engine can be moved. See
    /// docs/layout.md.
    private func pinSonames(log: LogFile) throws {
        let header = paths.wineBuild.appending(path: "include/config.h")
        var lines = try String(contentsOf: header, encoding: .utf8).components(separatedBy: "\n")

        var pinned: [String: String] = [:]
        for recipe in BuildRecipe.all {
            guard let macro = recipe.wineSoname else { continue }
            let soname = "@loader_path/\(Self.engineLibrariesFromWineUnix)/\(recipe.installedName)"

            for index in lines.indices where lines[index].hasPrefix("#define \(macro) \"") {
                lines[index] = "#define \(macro) \"\(soname)\""
                pinned[macro] = soname
            }
            // configure leaves `/* #undef SONAME_LIBSDL2 */` where it found nothing, and a
            // build that carries on from there works, minus whatever that library did.
            guard pinned[macro] != nil else {
                throw WineError.sonameUndefined(macro: macro, library: recipe.installedName)
            }
            log.write("=== sonames \(macro) \(soname)\n")
        }

        try lines.joined(separator: "\n").write(to: header, atomically: true, encoding: .utf8)
    }

    private func verify(log: LogFile) async throws {
        let winemac = paths.wineUnixLibraries.appending(path: "winemac.so")
        let symbols = try await runner.run(Command(
            executable: URL(filePath: "/usr/bin/nm"), arguments: ["-a", winemac.path]
        ))
        guard symbols.succeeded, symbols.standardOutput.lowercased().contains("d3dmetal") else {
            throw WineError.glueMissing(at: winemac.path)
        }
        log.write("=== verify \(winemac.path) carries the D3DMetal glue\n")

        for recipe in BuildRecipe.all {
            guard let macro = recipe.wineSoname else { continue }
            let soname = "\(Self.engineLibrariesFromWineUnix)/\(recipe.installedName)"
            let target = paths.wineUnixLibraries.appending(path: soname)
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw WineError.sonameUnresolved(
                    macro: macro,
                    soname: "@loader_path/\(soname)",
                    from: paths.wineUnixLibraries.path
                )
            }
            log.write("=== verify \(macro) resolves to \(target.standardizedFileURL.path)\n")
        }
    }

    /// What CrossOver's tree calls itself. Read rather than asked of the built binary:
    /// running Wine needs a prefix, and creating one has hangs of its own to handle.
    private func installedVersion() -> String {
        let file = Component.crossover.unpackedURL(in: paths).appending(path: "VERSION")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
