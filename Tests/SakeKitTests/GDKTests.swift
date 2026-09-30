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

@Test func aTitleAsksForPlayFabAndWhatItsOwnTableWouldName() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }

    let dungeons = try GDKTitle(config: write(config(titleID: "6B9DE498"), to: paths.root.appending(path: "a")))
    let other = try GDKTitle(config: write(config(), to: paths.root.appending(path: "b")))

    #expect(dungeons.relyingParties == [.playFab, RelyingParty("rp://api.minecraftservices.com/")])
    #expect(other.relyingParties == [.playFab])
    #expect(RelyingParty.playFab.boundToDevice)
    #expect(!RelyingParty.identity.boundToDevice)
}

// MARK: - The mailbox

private let requestID = "{0F8A3C2E-1B4D-4E6F-9A7B-2C3D4E5F6A7B}"

private func mailbox(_ paths: Paths) -> GDKMailbox {
    GDKMailbox(bottle: Bottle(paths: paths, name: "gdk"))
}

/// What the runtime writes, Windows line endings and all.
@discardableResult
private func ask(_ mailbox: GDKMailbox, titleID: String = "12AB34CD", id: String = requestID,
                 format: String = "sake 1") throws -> URL {
    let folder = mailbox.directory.appending(path: titleID)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "request")
    try Data("\(format)\r\nrequest \(id)\r\n".utf8).write(to: url)
    return url
}

@Test func aRuntimesRequestIsFoundInItsBottle() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let box = mailbox(paths)
    try ask(box)

    #expect(box.directory.path.hasSuffix("/drive_c/users/crossover/AppData/Local/Sake"))
    #expect(box.requests() == [GDKMailbox.Request(bottle: "gdk", titleID: "12AB34CD", id: requestID)])
}

@Test func whatIsNotARequestIsLeftAlone() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let box = mailbox(paths)

    try ask(box, titleID: "NOTATITLE")
    try ask(box, titleID: "0000ABCD", format: "sake 2")
    try ask(box, titleID: "0000ABCE", id: "../../somewhere")
    try FileManager.default.createDirectory(
        at: box.directory.appending(path: "0000ABCF"), withIntermediateDirectories: true
    )

    #expect(box.requests().isEmpty)
}

@Test func aStaleRequestIsTakenAwayAndASettledOneIsNotOfferedAgain() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let box = mailbox(paths)
    let now = Date()

    let stale = try ask(box, titleID: "00000001")
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-21 * 60)], ofItemAtPath: stale.path
    )
    try ask(box, titleID: "00000002")
    try ask(box, titleID: "00000003")
    let settled = GDKMailbox.Request(bottle: "gdk", titleID: "00000002", id: requestID)
    let abandoned = GDKMailbox.Request(bottle: "gdk", titleID: "00000003", id: requestID)
    try box.answer(settled, with: .cancelled)
    try box.answer(abandoned, with: .waiting)

    #expect(box.requests(now: now) == [abandoned])
    #expect(!FileManager.default.fileExists(atPath: stale.path))
}

@Test func theAnswerAndTheSessionAreWrittenForTheRuntimeToRead() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let box = mailbox(paths)
    let asked = try ask(box)
    let request = try #require(box.requests().first)
    let folder = asked.deletingLastPathComponent()

    try box.answer(request, with: .failed("two\nlines"))
    #expect(try String(contentsOf: folder.appending(path: "answer"), encoding: .utf8)
        == "sake 1\nrequest \(requestID)\nstate failed\nreason two lines\n")

    let token = try #require(XboxToken(answer: Data("""
        {"IssueInstant":"2026-09-29T20:00:29Z","NotAfter":"2026-09-30T12:00:29Z","Token":"the-token",\
        "DisplayClaims":{"xui":[{"uhs":"42","xid":"2814630418365389","gtg":"Some One","agg":"Adult","prv":"190 191"}]}}
        """.utf8)))
    let session = XboxSession(
        user: try #require(token.user),
        tokens: ["http://xboxlive.com": token, "http://playfab.xboxlive.com/": token]
    )
    try box.write(session, for: request)
    let expiry = Int(token.notAfter.timeIntervalSince1970)
    let written = folder.appending(path: "session")
    #expect(try String(contentsOf: written, encoding: .utf8) == """
        sake 1
        xuid 2814630418365389
        gamertag Some One
        user-hash 42
        age-group Adult
        privileges 190 191
        token http://playfab.xboxlive.com/ \(expiry) the-token
        token http://xboxlive.com \(expiry) the-token

        """)
    #expect(try FileManager.default.attributesOfItem(atPath: written.path)[.posixPermissions] as? Int == 0o600)

    box.finish(GDKMailbox.Request(bottle: "gdk", titleID: "12AB34CD", id: "{\(UUID().uuidString)}"))
    #expect(FileManager.default.fileExists(atPath: asked.path))
    box.finish(request)
    #expect(!FileManager.default.fileExists(atPath: asked.path))
}

/// Stops the watch after `limit` looks.
private final class Looks: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private(set) var count = 0

    init(limit: Int) {
        self.limit = limit
    }

    func next() throws {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count >= limit { throw CancellationError() }
    }
}

@Test func watchingOffersEachRequestOnce() async throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let bottle = Bottle(paths: paths, name: "gdk")
    try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
    try Data().write(to: bottle.systemRegistry)
    try ask(GDKMailbox(bottle: bottle))
    let looks = Looks(limit: 3)

    var offered: [GDKMailbox.Request] = []
    for await request in GDKMailbox.watch(paths, sleep: { _ in try looks.next() }) {
        offered.append(request)
    }

    #expect(offered == [GDKMailbox.Request(bottle: "gdk", titleID: "12AB34CD", id: requestID)])
    #expect(looks.count == 3)
}
