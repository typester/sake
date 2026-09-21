import Foundation

public enum TitleStoreError: Error, Equatable, LocalizedError {
    case outsideBottle(String)
    case notThere(String)
    case unnamed
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .outsideBottle(let name):
            """
            \(name) is not inside this bottle. A title has to be a program in the bottle's \
            own drive_c — install it into the bottle first, and add it from there.
            """
        case .notThere(let path):
            "There is nothing at \(path) any more."
        case .unnamed:
            "A title needs a name."
        case .unreadable(let why):
            "The titles already in this bottle could not be read: \(why)"
        }
    }
}

/// The titles somebody added to one bottle by hand, kept in the bottle.
///
/// In the prefix rather than under `paths.root` because of what `layout.md` measured about
/// renaming: nothing inside a prefix names the prefix, so a rename stays a `moveItem` and
/// throwing the bottle away takes its titles with it. A file beside it would need both
/// operations to keep a second place in step.
public struct TitleStore: Sendable {
    public let bottle: Bottle

    public init(bottle: Bottle) {
        self.bottle = bottle
    }

    public var url: URL { bottle.url.appending(path: "sake-titles.json") }

    public func load() -> [Title] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Title].self, from: data)) ?? []
    }

    /// A title for `executable`, which must be a program inside this bottle.
    ///
    /// The executable is stored relative to `drive_c`, which is what lets the bottle be
    /// renamed or moved with the titles still pointing at something.
    public func title(
        at executable: URL,
        named typed: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> Title {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TitleStoreError.unnamed }

        let relative = try relativeToDriveC(executable)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw TitleStoreError.notThere(executable.path)
        }
        return Title(
            id: identifier(for: name),
            name: name,
            executable: relative,
            arguments: arguments,
            environment: environment
        )
    }

    public func add(_ title: Title) throws {
        var titles = load().filter { $0.id != title.id }
        titles.append(title)
        try write(titles)
    }

    public func remove(id: String) throws {
        try write(load().filter { $0.id != id })
    }

    public func contains(id: String) -> Bool {
        load().contains { $0.id == id }
    }

    private func write(_ titles: [Title]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(titles).write(to: url, options: .atomic)
    }

    /// Readable rather than a UUID: it names the run's log file, and `title-battle-net.log`
    /// is findable where `title-8C7F….log` is not.
    private func identifier(for name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        let base = slug.isEmpty ? "title" : slug
        let taken = Set(load().map(\.id))
        guard taken.contains(base) else { return base }
        return (2...)
            .lazy
            .map { "\(base)-\($0)" }
            .first { !taken.contains($0) } ?? base
    }

    private func relativeToDriveC(_ executable: URL) throws -> String {
        let root = bottle.driveC.standardizedFileURL.resolvingSymlinksInPath()
        let target = executable.standardizedFileURL.resolvingSymlinksInPath()
        let rootParts = root.pathComponents
        let targetParts = target.pathComponents
        guard targetParts.count > rootParts.count, Array(targetParts.prefix(rootParts.count)) == rootParts else {
            throw TitleStoreError.outsideBottle(executable.lastPathComponent)
        }
        return targetParts.dropFirst(rootParts.count).joined(separator: "/")
    }
}
