import CryptoKit
import Foundation

public enum GDKRuntimePhase: String, Sendable {
    case fetch
    case compile
    case verify
    case install
}

public enum GDKRuntimeEvent: Sendable, Equatable {
    case alreadyBuilt
    case started
    case phase(GDKRuntimePhase)
    case output(String)
    case built
    case failed(reason: String, log: URL?)
    case finished
}

/// Builds sake's GDK runtime from the `xgameruntime/` that Sake.app carries, with the engine's
/// PE compiler, and keeps it in the engine for ``GDKRuntime`` to put in bottles. See
/// docs/gdk.md.
public struct GDKRuntimeBuilder: Sendable {
    private let paths: Paths
    private let runner: ProcessRunner
    public let sources: URL?
    let libHttpClientContents: String

    public init(
        paths: Paths = .default,
        sources: URL? = GDKRuntimeBuilder.bundled,
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.init(paths: paths, sources: sources, runner: runner,
                  libHttpClientContents: Self.pinnedLibHttpClient)
    }

    init(paths: Paths, sources: URL?, runner: ProcessRunner, libHttpClientContents: String) {
        self.paths = paths
        self.sources = sources
        self.runner = runner
        self.libHttpClientContents = libHttpClientContents
    }

    /// `xgameruntime/` inside the running app, which `scripts/build-app.sh` copies in the way
    /// it copies `patches/`.
    public static let bundled: URL? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appending(path: "xgameruntime")
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }()

    /// ``contentsHash(of:excluding:)`` of what ``Component/libHttpClient`` unpacks to. See
    /// docs/gdk.md.
    static let pinnedLibHttpClient = "08c0f1527e968da6d79996c95f195c43cc650f3e0073a04ab9cdb337ebe18c63"

    static let compilerName = "x86_64-w64-mingw32-clang++"

    public var logURL: URL { paths.build.appending(path: "xgameruntime.log") }

    private var runtime: GDKRuntime { GDKRuntime(paths: paths) }
    private var stampURL: URL { paths.gdkRuntime.appending(path: "source.sha256") }

    /// Built, and from the source this copy of sake carries. Without that source there is
    /// nothing to compare with, and a runtime that is there counts.
    public var isBuilt: Bool {
        guard FileManager.default.fileExists(atPath: runtime.dll.path) else { return false }
        guard let expected = expectedStamp else { return true }
        let stamp = try? String(contentsOf: stampURL, encoding: .utf8)
        return stamp?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    public var missingPrerequisite: String? {
        guard sources != nil else {
            return "This copy of sake is incomplete: it carries no source for its GDK runtime."
        }
        guard Component.llvmMinGW.isUnpacked(in: paths) else {
            return "The PE compiler is not unpacked yet. Download the sources first."
        }
        return nil
    }

    /// Everything the DLL is made from, as one hash. The source inside the app is hashed once
    /// per process: the wizard asks every step's state many times each time it draws.
    var expectedStamp: String? {
        guard let sources else { return nil }
        let tree = sources == Self.bundled
            ? Self.bundledContents
            : Self.contentsHash(of: sources, excluding: ["README.md"])
        guard let tree else { return nil }
        let recipe = [
            "xgameruntime \(tree)",
            "libhttpclient \(Component.libHttpClient.url.absoluteString) \(libHttpClientContents)",
            "llvm-mingw \(Component.llvmMinGW.url.absoluteString) \(Component.llvmMinGW.sha256 ?? "")",
            "cxx \(Self.compilerName)",
        ]
        return Self.hex(SHA256.hash(data: Data(recipe.joined(separator: "\n").utf8)))
    }

    private static let bundledContents: String? = bundled.flatMap {
        contentsHash(of: $0, excluding: ["README.md"])
    }

    /// Every regular file under `directory` that is not hidden and not in `excluded`, as one
    /// hash of their relative paths and their own hashes, in path order.
    static func contentsHash(of directory: URL, excluding excluded: Set<String> = []) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = FileManager.default.enumerator(atPath: directory.path)
        else { return nil }

        var files: [String] = []
        while let relative = entries.nextObject() as? String {
            let type = entries.fileAttributes?[.type] as? FileAttributeType
            if URL(filePath: relative).lastPathComponent.hasPrefix(".") {
                if type == .typeDirectory { entries.skipDescendants() }
                continue
            }
            if type == .typeRegular, !excluded.contains(relative) { files.append(relative) }
        }

        var hasher = SHA256()
        for relative in files.sorted() {
            guard let digest = try? SourceFetcher.sha256(of: directory.appending(path: relative))
            else { return nil }
            hasher.update(data: Data("\(relative)\0\(digest)\n".utf8))
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    public func build() -> AsyncStream<GDKRuntimeEvent> {
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
                        continuation.yield(.built)
                    } catch {
                        if !Task.isCancelled {
                            let fromARun = (error as? GDKRuntimeError)?.cameFromARun ?? true
                            continuation.yield(.failed(
                                reason: error.localizedDescription, log: fromARun ? logURL : nil
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

    private func run(
        onPhase: @Sendable (GDKRuntimePhase) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        if let missing = missingPrerequisite { throw GDKRuntimeError.notReady(missing) }
        guard let sources else { return }

        try FileManager.default.createDirectory(at: paths.build, withIntermediateDirectories: true)
        let log = try LogFile(at: logURL)
        defer { log.close() }

        onPhase(.fetch)
        let libHttpClient = try await fetchLibHttpClient(log: log, onOutput: onOutput)

        onPhase(.compile)
        // From nothing every time: make goes by mtimes, so an object left from other source
        // could end up in a DLL stamped as this source's.
        try? FileManager.default.removeItem(at: paths.gdkRuntimeBuild)
        let compiler = Component.llvmMinGW.unpackedURL(in: paths).appending(path: "bin/\(Self.compilerName)")
        let arguments = [
            "-C", sources.path,
            "-j\(ProcessInfo.processInfo.activeProcessorCount)",
            "CXX=\(compiler.path)",
            "LIBHTTPCLIENT=\(libHttpClient.path)",
            "OUT=\(paths.gdkRuntimeBuild.path)",
        ]
        log.write("=== compile /usr/bin/make \(arguments.joined(separator: " "))\n")
        let result = try await runner.run(
            Command(executable: URL(filePath: "/usr/bin/make"), arguments: arguments, architecture: .native)
        ) { line in
            log.write(line.text + "\n")
            onOutput(line.text)
        }
        guard result.succeeded else {
            throw GDKRuntimeError.compileFailed(status: result.exitStatus, log: logURL.path)
        }

        onPhase(.verify)
        let built = paths.gdkRuntimeBuild.appending(path: GDKRuntime.dllName)
        guard let dll = try? Data(contentsOf: built), GDKRuntime.carriesMarker(dll) else {
            throw GDKRuntimeError.markerMissing(at: built.path)
        }
        log.write("=== verify \(built.path) carries the marker\n")

        onPhase(.install)
        try FileManager.default.createDirectory(at: paths.gdkRuntime, withIntermediateDirectories: true)
        try GDKRuntime.write(dll, to: runtime.dll)
        try GDKRuntime.write(Data(contentsOf: libHttpClient.appending(path: "LICENSE.md")), to: runtime.licence)
        // Last, so that an install stopped part way does not count as this source's.
        if let stamp = expectedStamp {
            try GDKRuntime.write(Data("\(stamp)\n".utf8), to: stampURL)
        }
        log.write("=== install \(runtime.dll.path)\n")
    }

    /// Fetched here rather than with the other sources, and checked by what it unpacks to. See
    /// ``Component/libHttpClient``.
    private func fetchLibHttpClient(
        log: LogFile,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let component = Component.libHttpClient
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        for await event in SourceFetcher(paths: paths, session: session).fetch([component]) {
            switch event {
            case .alreadyInPlace:
                log.write("=== fetch \(component.id) already unpacked\n")
            case .progress(_, let bytes, _):
                onOutput("\(component.id) \(bytes / 1024) KB")
            case .unpacked:
                log.write("=== fetch \(component.id) unpacked\n")
            case .failed(_, let reason):
                throw GDKRuntimeError.fetchFailed(reason)
            case .started, .downloaded, .finished:
                break
            }
        }

        let tree = component.unpackedURL(in: paths)
        guard Self.contentsHash(of: tree) == libHttpClientContents else {
            try? FileManager.default.removeItem(at: tree)
            try? FileManager.default.removeItem(at: component.archiveURL(in: paths))
            throw GDKRuntimeError.libHttpClientChanged(at: tree.path)
        }
        log.write("=== fetch \(tree.path) is the source sake pins\n")
        return tree
    }
}
