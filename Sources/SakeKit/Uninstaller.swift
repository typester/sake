import Foundation

public enum UninstallEvent: Sendable, Equatable {
    case started
    case stopping(bottle: String)
    case removing(String)
    case removed(String, to: URL?)
    case failed(reason: String)
    case finished(removed: Int)
}

/// Takes away everything sake put on the disk, and nothing else.
///
/// Not the app bundle: it is running, and a bundle in `/Applications` is the user's to drag
/// away. See docs/layout.md.
public struct Uninstaller: Sendable {
    private let paths: Paths
    private let runner: ProcessRunner

    public init(paths: Paths = .default, runner: ProcessRunner = ProcessRunner()) {
        self.paths = paths
        self.runner = runner
    }

    /// One line of what uninstalling takes away, for something to list and size.
    ///
    /// Listed a piece at a time although ``roots`` is what moves, because "1.1 GB engine,
    /// 101 GB of games, 4 GB of downloads" is the question somebody uninstalling is
    /// actually asking.
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let url: URL
    }

    public func items() -> [Item] {
        var found = [Item(id: "engine", name: "The engine", url: paths.engine)]
        found += Bottle.all(in: paths).map {
            Item(id: "bottle-\($0.name)", name: "Bottle “\($0.name)”", url: $0.url)
        }
        found.append(Item(id: "sign-ins", name: "Xbox sign-ins", url: paths.signIns))
        found.append(
            Item(id: "cache", name: "Downloads and build files", url: paths.cache)
        )
        return found.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// The two directories that actually move. Everything in ``items()`` is inside one of
    /// them, and the user gets two things in the Trash rather than one per bottle.
    public var roots: [URL] { [paths.root, paths.cache] }

    public func run(trash: Trash = .system) -> AsyncStream<UninstallEvent> {
        AsyncStream { continuation in
            let work = Task {
                continuation.yield(.started)
                var removed = 0
                do {
                    // Every bottle first, and all of them before anything moves: taking one
                    // away while another is still live is a state nothing here needs.
                    for bottle in Bottle.all(in: paths) {
                        try Task.checkCancellation()
                        continuation.yield(.stopping(bottle: bottle.name))
                        _ = await bottle.takeDown(runner: runner)
                    }

                    for root in roots
                    where FileManager.default.fileExists(atPath: root.path) {
                        try Task.checkCancellation()
                        continuation.yield(.removing(root.path))
                        let landed = try trash.take(root)
                        continuation.yield(.removed(root.path, to: landed))
                        removed += 1
                    }
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.failed(reason: error.localizedDescription))
                    }
                }
                continuation.yield(.finished(removed: removed))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
