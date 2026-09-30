import Foundation

/// A game built on Microsoft's GDK, found by the `MicrosoftGame.config` at the root of its
/// install.
///
/// Not a ``Title``: what sake starts is often a launcher, and the GDK game is somewhere
/// inside what the launcher installed — in Steam's `steamapps`, with Steam as the title.
/// See docs/gdk.md.
public struct GDKTitle: Sendable, Hashable, Identifiable {
    public let name: String
    /// Hexadecimal, as the config writes it.
    public let titleID: String
    /// The OAuth client the title signs in to Microsoft as, or `nil` for one that never does.
    public let msaAppID: String?
    public let directory: URL

    public var id: String { directory.path }

    public static let configName = "MicrosoftGame.config"

    public init(config: URL) throws {
        let document: XMLDocument
        do {
            document = try XMLDocument(contentsOf: config)
        } catch {
            throw GDKTitleError.unreadable(config.path)
        }
        func text(_ path: String) -> String? {
            let value = (try? document.nodes(forXPath: path))?.first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }

        guard let titleID = text("/Game/TitleId"), UInt32(titleID, radix: 16) != nil else {
            throw GDKTitleError.noTitleID(config.path)
        }
        let directory = config.deletingLastPathComponent()
        let displayName = text("/Game/ShellVisuals/@DefaultDisplayName")

        self.titleID = titleID
        self.msaAppID = text("/Game/MSAAppId")
        self.directory = directory
        // A name from the title's resource table is a key, not a name.
        self.name = displayName.flatMap { $0.hasPrefix("ms-resource:") ? nil : $0 }
            ?? directory.lastPathComponent
    }

    /// Every GDK game under the bottle's two `Program Files`, by name. Five levels down is
    /// where Steam puts a config, in `Steam/steamapps/common/<game>/`.
    public static func all(in bottle: Bottle) -> [GDKTitle] {
        var found: [GDKTitle] = []
        for root in ["Program Files", "Program Files (x86)"] {
            search(bottle.driveC.appending(path: root), level: 0, into: &found)
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let deepest = 4

    private static func search(_ directory: URL, level: Int, into found: inout [GDKTitle]) {
        let config = directory.appending(path: configName)
        if FileManager.default.fileExists(atPath: config.path), let title = try? GDKTitle(config: config) {
            found.append(title)
            return
        }
        guard level < deepest else { return }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            search(entry, level: level + 1, into: &found)
        }
    }
}

public enum GDKTitleError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case noTitleID(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): "\(path) is not an XML file sake can read"
        case .noTitleID(let path): "\(path) names no title ID"
        }
    }
}
