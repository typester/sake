import Foundation

/// One Wine prefix, and the environment everything in the engine has to be run with.
///
/// The bottle directory *is* the `WINEPREFIX`, and the games live in its `drive_c`. See
/// docs/layout.md.
public struct Bottle: Sendable, Equatable {
    public let paths: Paths
    public let name: String

    public init(paths: Paths = .default, name: String = Bottle.defaultName) {
        self.paths = paths
        self.name = name
    }

    /// The one the setup wizard makes. Every other bottle is named by whoever made it.
    public static let defaultName = "default"

    /// Every prefix under `paths.bottles`, in name order.
    ///
    /// Filtered by ``exists`` rather than by being a directory, which drops a bottle whose
    /// creation was stopped half way for the same reason it drops `.DS_Store`.
    public static func all(in paths: Paths = .default) -> [Bottle] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: paths.bottles.path)) ?? []
        return entries.sorted().map { Bottle(paths: paths, name: $0) }.filter(\.exists)
    }

    /// What somebody typed, without the spaces they did not mean.
    public static func proposedName(from typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What is wrong with `typed` as a bottle's name, as a sentence, or `nil` when nothing
    /// is. `renaming` is the name of the bottle being renamed, which does not count as
    /// taking the name it already has.
    ///
    /// Spaces are deliberately allowed, although this repository has a standing rule against
    /// them in paths: that rule is about the engine, which is an autotools `--prefix` and
    /// word-splits out of `CPPFLAGS`. A bottle name reaches Wine as the value of `WINEPREFIX`
    /// in an environment sake composes, and never goes through a shell. See docs/layout.md.
    public static func problem(
        withName typed: String, in paths: Paths = .default, renaming current: String? = nil
    ) -> String? {
        let name = proposedName(from: typed)

        if name.isEmpty { return "A bottle needs a name." }
        if name.contains("/") {
            return "A bottle name is one folder's name, so it cannot contain a slash."
        }
        if name.hasPrefix(".") {
            return "A name starting with a dot would make a bottle you could not see."
        }
        if let taken = all(in: paths).first(where: {
            $0.name != current && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            // Case-insensitively, because APFS is by default: "Default" and "default" would
            // be one directory and the second wineboot would run inside the first bottle.
            return "There is already a bottle called \(taken.name)."
        }
        return nil
    }

    public var url: URL { paths.bottle(named: name) }
    public var engine: URL { paths.engine }

    public var driveC: URL { url.appending(path: "drive_c") }
    public var system32: URL { driveC.appending(path: "windows/system32") }
    public var sysWoW64: URL { driveC.appending(path: "windows/syswow64") }
    public var systemRegistry: URL { url.appending(path: "system.reg") }

    /// The registry rather than the directory: a run that was stopped half way leaves the
    /// directory behind, and a prefix without a registry is not one.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: systemRegistry.path)
    }

    /// What Wine put in the two system directories. `syswow64` empty means WoW64 never
    /// initialised, so no 32-bit application will run -- and Battle.net's launcher is
    /// 32-bit. It is the prototype's one acceptance check on a new prefix.
    public func systemFileCounts() -> (system32: Int, sysWoW64: Int) {
        func count(_ directory: URL) -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
        }
        return (count(system32), count(sysWoW64))
    }

    /// Everything a wine run needs, in one place. Each of these is here because leaving it
    /// out breaks something that does not look related; see docs/runtime.md.
    public func environment(
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["WINEPREFIX"] = url.path
        // Not optional. Without mscoree and mshtml disabled, wineboot puts up the Wine Mono
        // installer and waits for a click that never comes: 0% CPU forever, and syswow64
        // never populated.
        environment["WINEDLLOVERRIDES"] = "mscoree,mshtml=d"
        // Leave this at -all. With err+all a failed dlopen produces a dlerror() string long
        // enough to overflow Wine's debug buffer, and the exception cannot then be
        // dispatched -- so raising the log level turns a handled failure into a crash.
        environment["WINEDEBUG"] = "-all"
        // CodeWeavers' CW Hack 22996, off by default, and the one thing that makes
        // Battle.net's login page load at all.
        environment["WINE_SIMULATE_WRITECOPY"] = "1"
        // Only when the library is really there: Wine looks up Rosetta's
        // register_non_native_code_region only if this points at it, and a variable
        // pointing at nothing would read as "D3DMetal is set up" everywhere downstream.
        if FileManager.default.fileExists(atPath: paths.d3dSharedLibrary.path) {
            environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = paths.d3dSharedLibrary.path
        }
        return environment
    }

    /// One of the engine's own binaries, run in this bottle.
    ///
    /// Never translated. Wine's binaries are x86_64 already so Rosetta handles them, and
    /// `arch` is a hardened system binary whose exec strips every `DYLD_*` variable -- so
    /// wrapping a *run* the way the build is wrapped takes the environment away. See
    /// docs/wine-build.md.
    public func command(
        _ program: String,
        _ arguments: [String] = [],
        workingDirectory: URL? = nil,
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> Command {
        Command(
            executable: engine.appending(path: "bin/\(program)"),
            arguments: arguments,
            environment: environment(inheriting: base),
            workingDirectory: workingDirectory,
            architecture: .native
        )
    }

    /// Kill this prefix's wineserver.
    ///
    /// Not the whole of taking a bottle down -- see ``takeDown(runner:)``, which this is
    /// the first half of. `wineserver -k` without `WINEPREFIX` goes after the default
    /// `~/.wine`, kills nothing of yours and exits 0, which is why this is a method on the
    /// bottle rather than a command anyone may assemble.
    @discardableResult
    public func stop(runner: ProcessRunner = ProcessRunner()) async throws -> CommandResult {
        try await runner.run(command("wineserver", ["-k"]))
    }

    /// Where wineserver keeps this prefix's socket: `/tmp/.wine-<uid>/server-<dev>-<inode>`,
    /// both halves hex, taken from the prefix directory itself.
    ///
    /// This is the only thing on the machine that says which prefix a running Wine process
    /// belongs to -- `ps` shows `C:\windows\system32\services.exe` and nothing else --
    /// and because it is an inode it survives the bottle being renamed. Measured against a
    /// live prefix on 2026-09-20; see docs/runtime.md.
    public var serverDirectory: URL? {
        // Resolved first: Wine `chdir`s into the prefix and stats `.`, so a bottle that is a
        // symlink is named by its target, and `attributesOfItem` describes the link itself.
        guard let attributes = try? FileManager.default.attributesOfItem(
                  atPath: url.resolvingSymlinksInPath().path
              ),
              let device = attributes[.systemNumber] as? Int,
              let inode = attributes[.systemFileNumber] as? Int
        else { return nil }
        return URL(filePath: "/tmp/.wine-\(getuid())")
            .appending(path: "server-\(String(device, radix: 16))-\(String(inode, radix: 16))")
    }

    /// Everything running in this prefix, including what sake did not start.
    public func processes(runner: ProcessRunner = ProcessRunner()) async -> [Int32] {
        guard let directory = serverDirectory,
              FileManager.default.fileExists(atPath: directory.path)
        else { return [] }
        // lsof exits 1 when it finds nothing, which is not a failure here.
        let result = try? await runner.run(Command(
            executable: URL(filePath: "/usr/sbin/lsof"),
            arguments: ["-t", "-w", "+D", directory.path]
        ))
        return (result?.standardOutput ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Take the bottle down, and say what is still running afterwards.
    ///
    /// Killing wineserver is not enough on its own. Measured on 2026-09-20, after
    /// `wineserver -k` took down the game and the server: `services.exe`, two
    /// `winedevice.exe`, `plugplay.exe`, `svchost.exe`, `explorer.exe` and `rpcss.exe` were
    /// still there with ppid 1, and stayed for the rest of the session -- long enough for
    /// the Dock to keep showing an app that had already exited. Six of the seven took
    /// SIGTERM; one needed SIGKILL.
    @discardableResult
    public func takeDown(runner: ProcessRunner = ProcessRunner()) async -> [Int32] {
        _ = try? await stop(runner: runner)
        try? await Task.sleep(for: .seconds(1))

        let afterServer = await processes(runner: runner)
        guard !afterServer.isEmpty else { return [] }
        for pid in afterServer { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(2))

        let afterTerm = await processes(runner: runner)
        guard !afterTerm.isEmpty else { return [] }
        for pid in afterTerm { kill(pid, SIGKILL) }
        try? await Task.sleep(for: .seconds(1))

        return await processes(runner: runner)
    }

    /// Give the bottle another name, which is a directory rename and nothing else.
    ///
    /// Nothing inside a prefix names the prefix: measured on 2026-09-19, the three
    /// registries carry no path into `bottles/`, no symlink points back in, and
    /// `dosdevices/c:` is relative. See docs/layout.md.
    public func rename(
        to typed: String, runner: ProcessRunner = ProcessRunner()
    ) async throws -> Bottle {
        if let problem = Self.problem(withName: typed, in: paths, renaming: name) {
            throw BottleError.badName(problem)
        }
        let renamed = Bottle(paths: paths, name: Self.proposedName(from: typed))
        guard renamed.name != name else { return self }

        await takeDown(runner: runner)
        // Including a change of case only, which `moveItem` handles although the volume is
        // case-insensitive and reports the new name as already existing. A guard on that
        // would refuse a legal rename; excluding this bottle from the collision check in
        // ``problem(withName:in:renaming:)`` is what makes it reachable. Measured 2026-09-19.
        try FileManager.default.moveItem(at: url, to: renamed.url)
        return renamed
    }

    /// Take the bottle away, and say where it went.
    ///
    /// Taken down first for the reason ``takeDown(runner:)`` exists: wineserver and the
    /// prefix's own services outlive whatever started them, and a bottle removed from
    /// under a running one is a live process writing into a tree nobody can find.
    @discardableResult
    public func remove(
        runner: ProcessRunner = ProcessRunner(), trash: Trash = .system
    ) async throws -> URL? {
        // A bottle outlives its engine: with no `bin/wineserver` there is nothing to kill,
        // and that must not be what stops somebody throwing the bottle away.
        await takeDown(runner: runner)
        return try trash.take(url)
    }
}

/// Where a removed bottle goes.
///
/// Injected for the reason ``ProcessRunner`` is: a test that used the real one would fill
/// the developer's Trash.
public struct Trash: Sendable {
    let take: @Sendable (URL) throws -> URL?

    public init(_ take: @escaping @Sendable (URL) throws -> URL?) {
        self.take = take
    }

    /// macOS's own. On one volume it is a rename, so it costs nothing however large the
    /// bottle -- and returns nothing either, until the Trash is emptied.
    public static let system = Trash { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// Not the Trash at all. Only ever reached after ``system`` has refused a bottle and
    /// the user has been told why, because nothing here can be put back.
    public static let permanent = Trash { url in
        try FileManager.default.removeItem(at: url)
        return nil
    }
}
