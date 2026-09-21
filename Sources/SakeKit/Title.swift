import Foundation

/// What sake has to know to start one game.
///
/// Every field here is something the prototype hard-coded in a shell script. Why each
/// argument is needed is in docs/runtime.md and is not restated beside the value, because
/// a comment next to data is the copy that goes stale.
public struct Title: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    /// Relative to the bottle's `drive_c`.
    public let executable: String
    public let arguments: [String]
    /// Put on this title's run only, underneath what ``Bottle/environment(inheriting:)``
    /// composes — so ``reservedEnvironmentNames`` cannot be changed from here.
    public let environment: [String: String]

    public init(
        id: String,
        name: String,
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// Written out because ``TitleStore/load()`` turns any decoding failure into an empty
    /// library: a synthesised decoder throws `keyNotFound` on every file written before
    /// `environment` existed, so every title would disappear without a word.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }

    /// What ``Bottle/environment(inheriting:)`` sets for itself, and a title may not.
    /// `WINE_SIMULATE_WRITECOPY` turned off is a Battle.net that never loads its login
    /// page, and a `WINEPREFIX` of your own is a run in somebody else's bottle.
    public static let reservedEnvironmentNames = [
        "WINEPREFIX",
        "WINEDLLOVERRIDES",
        "WINEDEBUG",
        "WINE_SIMULATE_WRITECOPY",
        "CX_APPLEGPTK_LIBD3DSHARED_PATH",
    ]

    public static func reservedNames(in environment: [String: String]) -> [String] {
        reservedEnvironmentNames.filter(environment.keys.contains)
    }

    /// One line of text into `argv`. Whitespace separates; a double-quoted run keeps its
    /// spaces, which is the only way to write a flag whose value contains one. The quotes
    /// group and are not passed on, the way a shell's are — nothing here goes through a
    /// shell, so this is the only place that spelling is understood.
    public static func arguments(from text: String) -> [String] {
        var found: [String] = []
        var current = ""
        var quoted = false
        var started = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                started = true
            } else if !quoted, character.isWhitespace {
                if started { found.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { found.append(current) }
        return found
    }

    /// `argv` back into one line, quoting only what would not survive the trip.
    public static func argumentsText(_ arguments: [String]) -> String {
        arguments
            .map { $0.isEmpty || $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// One `KEY=VALUE` per line. Split at the first `=` so a value may contain one, and a
    /// line that is not a variable at all is dropped rather than stored as a name with no
    /// value. Lines need no quoting, which is why the environment is not one field.
    public static func environment(from text: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            found[name] = String(trimmed[trimmed.index(after: separator)...])
        }
        return found
    }

    public static func environmentText(_ environment: [String: String]) -> String {
        environment.keys.sorted()
            .map { "\($0)=\(environment[$0] ?? "")" }
            .joined(separator: "\n")
    }

    public func executableURL(in bottle: Bottle) -> URL {
        bottle.driveC.appending(path: executable)
    }

    /// What the program is started from. Battle.net resolves things relative to its own
    /// directory, which is why the prototype changed into it before starting anything.
    public func directoryURL(in bottle: Bottle) -> URL {
        executableURL(in: bottle).deletingLastPathComponent()
    }

    /// The leaf name, which is both what is passed as `argv[0]` and what a `ps` line is
    /// matched against.
    public var program: String {
        executable.split(separator: "/").last.map(String.init) ?? executable
    }

    public func isInstalled(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: executableURL(in: bottle).path)
    }

    /// What can be started in this bottle: what somebody added to it, filtered by what is
    /// still there.
    ///
    /// sake ships no titles of its own. It knew one game once, which meant a row appeared
    /// for that one and for nothing else; what the row carried -- the Chromium flags -- is
    /// now ``suggestedArguments(for:)``, which answers for any program rather than for one.
    public static func installed(in bottle: Bottle) -> [Title] {
        TitleStore(bottle: bottle).load().filter { $0.isInstalled(in: bottle) }
    }

    /// The flags a Chromium app needs here, or nothing at all.
    ///
    /// `--use-gl=angle --use-angle=vulkan` and `--in-process-gpu` are Chromium's, not
    /// Wine's: they mean something to a CEF app and nothing to a game, which is why they
    /// are not simply put on everything the way the two environment variables in
    /// `Bottle.environment` are. See docs/runtime.md.
    ///
    /// **`libcef.dll` is looked for one directory down as well as beside the program.**
    /// Battle.net's own exe sits in `Battle.net/` and its CEF build in
    /// `Battle.net/Battle.net.<build>/`, so beside-only finds nothing. Measured against a
    /// real install on 2026-09-20.
    public static func suggestedArguments(for executable: URL) -> [String] {
        let chromium = ["--use-gl=angle", "--use-angle=vulkan", "--in-process-gpu"]
        let directory = executable.deletingLastPathComponent()
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.appending(path: "libcef.dll").path) {
            return chromium
        }
        let entries = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in entries {
            let below = directory.appending(path: entry).appending(path: "libcef.dll")
            if manager.fileExists(atPath: below.path) { return chromium }
        }
        return []
    }
}
