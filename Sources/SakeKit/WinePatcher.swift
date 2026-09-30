import CryptoKit
import Foundation

public struct WinePatch: Sendable, Equatable, Identifiable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var id: String { url.lastPathComponent }

    /// The first line of the file, which is where each patch says what it does.
    public var subject: String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return String(text.prefix(while: { !$0.isNewline }))
    }

    /// The files this patch changes, relative to the tree, as its `--- a/` lines name them.
    public var targets: [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n")
            .filter { $0.hasPrefix("--- a/") }
            .map { String($0.dropFirst("--- a/".count)) }
    }
}

public enum PatchError: Error, Equatable, LocalizedError {
    case directoryMissing
    case noPatches(directory: String)
    case doesNotApply(patch: String, tree: String)

    public var errorDescription: String? {
        switch self {
        case .directoryMissing:
            """
            This copy of sake is incomplete: it carries no patches, and the Wine it would \
            build could not start a game.
            """
        case .noPatches(let directory):
            "\(directory) holds no patches, and Wine cannot be built without them."
        case .doesNotApply(let patch, let tree):
            """
            \(patch) applies to neither the original nor the patched form of \(tree). \
            These patches are written against CrossOver's sources and have to be rebased \
            when CodeWeavers publish new ones.
            """
        }
    }
}

/// Applies the patches in `patches/` to the unpacked CrossOver tree.
///
/// Zero patches is an error rather than a quiet success: Wine builds, installs and passes
/// every check this repository makes without them, and only fails much later at the thing
/// the patches exist for. See `docs/runtime.md`.
public struct WinePatcher: Sendable {
    public let directory: URL?
    private let runner: ProcessRunner

    public init(directory: URL? = WinePatcher.bundled, runner: ProcessRunner = ProcessRunner()) {
        self.directory = directory
        self.runner = runner
    }

    /// `patches/` inside the running app. Not a SwiftPM resource bundle: the patches are
    /// their own licence, and burying them in `Sources/` to satisfy `Bundle.module` would
    /// hide that. `scripts/build-app.sh` copies the directory in.
    public static var bundled: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appending(path: "patches")
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return directory
    }

    public func patches() throws -> [WinePatch] {
        guard let directory else { throw PatchError.directoryMissing }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let patches = files
            .filter { $0.pathExtension == "patch" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(WinePatch.init)
        guard !patches.isEmpty else { throw PatchError.noPatches(directory: directory.path) }
        return patches
    }

    /// Every patch's name and contents as one hash, which the engine keeps to say what it was
    /// built from, or `nil` when there are no patches to hash. See docs/wine-build.md.
    public func fingerprint() -> String? {
        guard let patches = try? patches() else { return nil }
        var hasher = SHA256()
        for patch in patches {
            guard let digest = try? SourceFetcher.sha256(of: patch.url) else { return nil }
            hasher.update(data: Data("\(patch.id)\0\(digest)\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Apply every patch to `tree`, skipping the ones already in it.
    ///
    /// Whether a patch is already applied is asked of `patch` itself -- if it reverses
    /// cleanly it is in -- rather than recorded in a marker file, which would have to be
    /// invalidated by hand every time a patch here changed. Patches that change the same
    /// lines stack, and one under the top of its stack reverses neither on its own nor
    /// applies again; for those the stack is what is asked. See docs/wine-build.md.
    public func apply(
        to tree: URL,
        onOutput: @Sendable (String) -> Void = { _ in }
    ) async throws {
        let patches = try patches()
        var index = 0
        while index < patches.count {
            let patch = patches[index]
            // Reversal is asked first. Apple's patch answers a forward dry run of a patch
            // that is already in with success as well: it notices the hunks are reversed,
            // asks whether to assume -R, takes the default yes at end of input, and exits
            // 0. The real run after it would then put the patch in twice.
            if try await runs(patch, on: tree, reversed: true, dryRun: true) {
                onOutput("already applied: \(patch.id)")
                index += 1
            } else if try await runs(patch, on: tree, reversed: false, dryRun: true) {
                _ = try await runs(patch, on: tree, reversed: false, dryRun: false)
                onOutput("applied: \(patch.id)")
                index += 1
            } else if let top = try await appliedRun(in: patches, from: index, tree: tree) {
                for applied in patches[index..<top] {
                    onOutput("already applied: \(applied.id) (under later patches)")
                }
                onOutput("already applied: \(patches[top].id)")
                index = top + 1
            } else {
                throw PatchError.doesNotApply(patch: patch.id, tree: tree.path)
            }
        }
    }

    /// The index of the top of the longest run `patches[start...]` that reverses top-down,
    /// or nil when no such run does. Reversing is done for real on a copy of the files the
    /// run touches, because a dry run cannot be sequenced; the tree itself is not touched.
    private func appliedRun(in patches: [WinePatch], from start: Int, tree: URL) async throws -> Int? {
        for top in stride(from: patches.count - 1, through: start, by: -1) {
            let run = Array(patches[start...top])
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "sake-patch-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: copy) }
            guard copyTargets(of: run, from: tree, to: copy) else { continue }

            var reversed = true
            for patch in run.reversed() {
                let ok = try await runs(patch, on: copy, reversed: true, dryRun: false)
                if !ok { reversed = false; break }
            }
            if reversed { return top }
        }
        return nil
    }

    private func copyTargets(of patches: [WinePatch], from tree: URL, to copy: URL) -> Bool {
        let manager = FileManager.default
        for target in Set(patches.flatMap(\.targets)) {
            let source = tree.appending(path: target)
            let destination = copy.appending(path: target)
            do {
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try manager.copyItem(at: source, to: destination)
            } catch {
                return false
            }
        }
        return true
    }

    private func runs(
        _ patch: WinePatch, on tree: URL, reversed: Bool, dryRun: Bool
    ) async throws -> Bool {
        // No fuzz: with patch's default, a hunk whose outer context is not in this tree
        // applies wherever the rest of it fits and reports success. See docs/wine-build.md.
        var arguments = ["-d", tree.path, "-p1", "-F0", "-s", "-i", patch.url.path]
        // --force so that a reversed patch is reported in the exit status instead of
        // stopping to ask, which would hang a build with no terminal to answer it.
        if reversed { arguments += ["-R", "--force"] }
        if dryRun { arguments.append("--dry-run") }

        let result = try await runner.run(Command(
            executable: URL(filePath: "/usr/bin/patch"), arguments: arguments
        ))
        return result.succeeded
    }
}
