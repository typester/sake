import Foundation
import Testing

@testable import SakeKit

private func temporaryRoot() -> Paths {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-gdk-\(UUID().uuidString)")
    return Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
}

private func remove(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
}

/// Shaped like the config a Steam install of a GDK game carries, byte order mark included,
/// with made-up identities.
private func config(titleID: String = "12AB34CD", msaAppID: String? = "0000000012345678",
                    displayName: String = "Example Game") -> String {
    let msa = msaAppID.map { "\n  <MSAAppId>\($0)</MSAAppId>" } ?? ""
    return """
        \u{FEFF}<?xml version="1.0" encoding="utf-8"?>
        <Game configVersion="1">
          <Identity Name="Example.Game" Publisher="CN=Example" Version="1.0.0.0" />
          <ShellVisuals DefaultDisplayName="\(displayName)" PublisherDisplayName="Example" />
          <ExecutableList>
            <Executable Name="Game.exe" Id="Game" TargetDeviceFamily="PC" />
          </ExecutableList>
          <TitleId>\(titleID)</TitleId>\(msa)
          <RequiresXboxLive>false</RequiresXboxLive>
        </Game>
        """
}

private func write(_ text: String, to directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: GDKTitle.configName)
    try Data(text.utf8).write(to: url)
    return url
}

@Test func readsATitlesIdentityFromItsConfig() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }

    let title = try GDKTitle(config: write(config(), to: paths.root.appending(path: "Example")))

    #expect(title.name == "Example Game")
    #expect(title.titleID == "12AB34CD")
    #expect(title.msaAppID == "0000000012345678")
    #expect(title.directory.lastPathComponent == "Example")
}

@Test func aTitleThatNeverSignsInIsStillAGDKTitle() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }

    let url = try write(
        config(msaAppID: nil, displayName: "ms-resource:AppDisplayName"),
        to: paths.root.appending(path: "Quiet Game")
    )
    let title = try GDKTitle(config: url)

    #expect(title.msaAppID == nil)
    #expect(title.name == "Quiet Game")
}

@Test func aFileThatIsNotAConfigIsRefused() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }

    let garbage = try write("not xml at all", to: paths.root.appending(path: "a"))
    #expect(throws: GDKTitleError.unreadable(garbage.path)) { try GDKTitle(config: garbage) }

    let noID = try write("<Game><MSAAppId>0000000012345678</MSAAppId></Game>", to: paths.root.appending(path: "b"))
    #expect(throws: GDKTitleError.noTitleID(noID.path)) { try GDKTitle(config: noID) }
}

@Test func findsATitleWhereSteamOrEpicInstallsIt() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let drive = Bottle(paths: paths, name: "gdk").driveC

    _ = try write(config(displayName: "From Steam"),
                  to: drive.appending(path: "Program Files (x86)/Steam/steamapps/common/Game"))
    _ = try write(config(displayName: "From Epic"),
                  to: drive.appending(path: "Program Files/Epic Games/Other"))
    _ = try write(config(displayName: "Too Deep"),
                  to: drive.appending(path: "Program Files/a/b/c/d/e"))
    _ = try write(config(displayName: "Hidden"),
                  to: drive.appending(path: "Program Files/.hidden/Game"))
    _ = try write(config(displayName: "Outside"),
                  to: drive.appending(path: "windows/Game"))

    let found = GDKTitle.all(in: Bottle(paths: paths, name: "gdk"))

    #expect(found.map(\.name) == ["From Epic", "From Steam"])
}
