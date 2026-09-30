import CryptoKit
import Foundation
import Testing

@testable import SakeKit

/// Answers each request with the next of `answers`, and keeps what was sent. Tests run in
/// parallel, so each makes its own.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(Int, String)]
    private var sent: [URLRequest] = []

    init(_ answers: [(Int, String)]) {
        self.answers = answers
    }

    var transport: HTTPTransport {
        HTTPTransport { request in try self.answer(request) }
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        sent.append(request)
        guard !answers.isEmpty else { throw URLError(.cannotConnectToHost) }
        let (status, body) = answers.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    func record(_ duration: Duration) {
        lock.lock()
        recorded.append(duration)
        lock.unlock()
    }

    var all: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func fromBase64URL(_ text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}

private func form(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
    }
    return fields
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
}

/// Rebuilds the stream Microsoft's documentation says is signed, from the request as the
/// server received it, and checks the header against it with the public key.
private func signatureHolds(
    _ request: URLRequest, path: String, key: ProofKey, maxBodyBytes: Int = .max
) throws -> Bool {
    let header = try #require(request.value(forHTTPHeaderField: "Signature"))
    let bytes = try #require(Data(base64Encoded: header))
    #expect(bytes.count == 4 + 8 + 64)
    #expect(Array(bytes.prefix(4)) == [0, 0, 0, 1])

    var message = Data([0, 0, 0, 1, 0])
    message += bytes[4..<12] + [0]
    message += Data((request.httpMethod ?? "GET").utf8) + [0]
    message += Data(path.utf8) + [0]
    message += Data((request.value(forHTTPHeaderField: "Authorization") ?? "").utf8) + [0]
    message += (request.httpBody ?? Data()).prefix(maxBodyBytes) + [0]

    let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes[12...])
    return key.key.publicKey.isValidSignature(signature, for: message)
}

// MARK: - The proof key

@Test func aProofKeyIsTheJWKXboxLiveReadsBack() throws {
    let key = ProofKey()
    let jwk = key.jwk

    #expect(jwk["alg"] == "ES256")
    #expect(jwk["crv"] == "P-256")
    #expect(jwk["kty"] == "EC")
    #expect(jwk["use"] == "sig")
    for coordinate in [jwk["x"], jwk["y"]] {
        let text = try #require(coordinate)
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
    }
    let x = try #require(fromBase64URL(jwk["x"]!))
    let y = try #require(fromBase64URL(jwk["y"]!))
    #expect(Data([4]) + x + y == key.key.publicKey.x963Representation)

    let again = try ProofKey(rawRepresentation: key.rawRepresentation)
    #expect(again.jwk == jwk)
}

@Test func theUnixEpochIsItsWindowsFileTime() {
    #expect(ProofKey.fileTime(Date(timeIntervalSince1970: 0)) == 116_444_736_000_000_000)
    #expect(ProofKey.fileTime(Date(timeIntervalSince1970: 1.5)) == 116_444_736_015_000_000)
}

@Test func aSignatureCoversTheRequestAsItIsSent() throws {
    let key = ProofKey()
    var request = URLRequest(url: URL(string: "https://title.mgt.xboxlive.com/titles/1805509784/endpoints?type=1")!)
    request.setValue("XBL3.0 x=123;token", forHTTPHeaderField: "Authorization")
    request.httpBody = Data("{\"a\":1}".utf8)
    request.httpMethod = "POST"

    let header = try key.signature(for: request, at: now)
    request.setValue(header, forHTTPHeaderField: "Signature")

    #expect(try signatureHolds(request, path: "/titles/1805509784/endpoints?type=1", key: key))
    let time = try #require(Data(base64Encoded: header))[4..<12]
    #expect(time.reduce(0) { $0 << 8 | UInt64($1) } == ProofKey.fileTime(now))
}

@Test func onlyThePolicysShareOfTheBodyIsSigned() throws {
    let key = ProofKey()
    var request = URLRequest(url: URL(string: "https://example.xboxlive.com/x")!)
    request.httpMethod = "POST"
    request.httpBody = Data("0123456789abcdef".utf8)
    request.setValue(try key.signature(for: request, at: now, maxBodyBytes: 8), forHTTPHeaderField: "Signature")

    #expect(try signatureHolds(request, path: "/x", key: key, maxBodyBytes: 8))
    #expect(try !signatureHolds(request, path: "/x", key: key))
}

@Test func thePathIsSignedAsItGoesOnTheRequestLine() {
    #expect(ProofKey.pathAndQuery(of: URL(string: "https://api.minecraftservices.com")) == "/")
    #expect(ProofKey.pathAndQuery(of: URL(string: "https://playfabapi.com/")) == "/")
    #expect(ProofKey.pathAndQuery(of: URL(string: "https://example.com/a%20b/?q=1%2B2")) == "/a%20b/?q=1%2B2")
}

// MARK: - The device code

private let codeAnswer = """
    {"user_code":"ABCD1234","device_code":"the-device-code","verification_uri":"https://www.microsoft.com/link",\
    "interval":5,"expires_in":900}
    """

private let tokenAnswer = """
    {"token_type":"bearer","expires_in":86400,"scope":"service::user.auth.xboxlive.com::MBI_SSL",\
    "access_token":"the-access-token","refresh_token":"the-refresh-token","user_id":"someone"}
    """

private func signIn(_ server: FakeServer, sleeps: Sleeps = Sleeps()) -> MicrosoftSignIn {
    MicrosoftSignIn(
        clientID: "0000000012345678",
        transport: server.transport,
        sleep: { sleeps.record($0) },
        now: { now }
    )
}

@Test func askingForACodeSendsTheTitlesOwnClientID() async throws {
    let server = FakeServer([(200, codeAnswer)])

    let code = try await signIn(server).requestCode()

    #expect(code.userCode == "ABCD1234")
    #expect(code.verificationURL == URL(string: "https://www.microsoft.com/link"))
    #expect(code.completeVerificationURL == nil)
    #expect(code.expiresAt == now.addingTimeInterval(900))

    let request = try #require(server.requests.first)
    #expect(request.url == MicrosoftSignIn.codeURL)
    #expect(request.httpMethod == "POST")
    #expect(form(request) == [
        "client_id": "0000000012345678",
        "scope": "service::user.auth.xboxlive.com::MBI_SSL",
        "response_type": "device_code",
    ])
}

@Test func aPlusInAFormFieldIsEncoded() {
    #expect(MicrosoftSignIn.formBody([("a", "x+y z"), ("b", "M.C5_BAY.2!")]) == "a=x%2By%20z&b=M.C5_BAY.2%21")
}

@Test func waitingPollsUntilTheCodeIsApproved() async throws {
    let server = FakeServer([
        (200, codeAnswer),
        (400, #"{"error":"authorization_pending","error_description":"not yet"}"#),
        (400, #"{"error":"slow_down"}"#),
        (200, tokenAnswer),
    ])
    let sleeps = Sleeps()
    let sign = signIn(server, sleeps: sleeps)

    let tokens = try await sign.waitForApproval(of: sign.requestCode())

    #expect(tokens == MicrosoftSignIn.Tokens(
        accessToken: "the-access-token",
        refreshToken: "the-refresh-token",
        expiresAt: now.addingTimeInterval(86400)
    ))
    #expect(sleeps.all == [.seconds(5), .seconds(5), .seconds(10)])
    for poll in server.requests.dropFirst() {
        #expect(poll.url == MicrosoftSignIn.tokenURL)
        #expect(form(poll)["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(form(poll)["device_code"] == "the-device-code")
    }
}

@Test func aDeclinedOrExpiredCodeEndsTheWait() async throws {
    for (error, expected) in [("authorization_declined", MicrosoftSignInError.declined),
                              ("expired_token", .expired)] {
        let server = FakeServer([(200, codeAnswer), (400, #"{"error":"\#(error)"}"#)])
        let sign = signIn(server)
        let code = try await sign.requestCode()

        await #expect(throws: expected) { try await sign.waitForApproval(of: code) }
    }
}

@Test func cancellingTheWaitStopsIt() async throws {
    let server = FakeServer([(200, codeAnswer)])
    let sign = MicrosoftSignIn(clientID: "0000000012345678", transport: server.transport, now: { now })
    let code = try await sign.requestCode()

    let waiting = Task { try await sign.waitForApproval(of: code) }
    waiting.cancel()

    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(server.requests.count == 1)
}

@Test func refreshingKeepsTheRefreshTokenWhenNoNewOneComes() async throws {
    let server = FakeServer([(200, #"{"access_token":"a-new-access-token","expires_in":3600}"#)])

    let tokens = try await signIn(server).refresh("the-refresh-token")

    #expect(tokens.accessToken == "a-new-access-token")
    #expect(tokens.refreshToken == "the-refresh-token")
    let fields = form(try #require(server.requests.first))
    #expect(fields["grant_type"] == "refresh_token")
    #expect(fields["scope"] == MicrosoftSignIn.scope)
    #expect(fields["client_id"] == "0000000012345678")
}

// MARK: - Xbox Live's tokens

private let xstsAnswer = """
    {"IssueInstant":"2026-09-29T20:00:29.3191631Z","NotAfter":"2026-09-30T04:00:29.3191631Z",\
    "Token":"the-xsts-token","DisplayClaims":{"xui":[{"agg":"Adult","gtg":"Someone","prv":"190 191",\
    "xid":"2814630418365389","uhs":"1283950176146904870"}]}}
    """

private let deviceAnswer = """
    {"IssueInstant":"2026-09-29T20:00:29Z","NotAfter":"2026-10-13T20:00:29Z","Token":"the-device-token",\
    "DisplayClaims":{"xdi":{"did":"F700000000000000","dcs":"0"}}}
    """

private func auth(_ server: FakeServer) -> XboxLiveAuth {
    XboxLiveAuth(transport: server.transport, now: { now })
}

@Test func aDeviceTokenIsAskedForWithTheKeyItWillBeBoundTo() async throws {
    let server = FakeServer([(200, deviceAnswer)])
    let key = ProofKey()
    let id = UUID()

    let token = try await auth(server).deviceToken(key: key, deviceID: id)

    #expect(token.token == "the-device-token")
    #expect(token.user == nil)
    let request = try #require(server.requests.first)
    #expect(request.url == URL(string: "https://device.auth.xboxlive.com/device/authenticate"))
    #expect(request.value(forHTTPHeaderField: "x-xbl-contract-version") == "1")
    #expect(try signatureHolds(request, path: "/device/authenticate", key: key))

    let body = try json(request)
    #expect(body["RelyingParty"] as? String == "http://auth.xboxlive.com")
    let properties = try #require(body["Properties"] as? [String: Any])
    #expect(properties["AuthMethod"] as? String == "ProofOfPossession")
    #expect(properties["DeviceType"] as? String == "Win32")
    #expect(properties["Id"] as? String == "{\(id.uuidString)}")
    #expect(properties["ProofKey"] as? [String: String] == key.jwk)
    #expect(!String(decoding: request.httpBody!, as: UTF8.self).contains(#"\/"#))
}

@Test func aUserTokenCarriesTheMicrosoftTicket() async throws {
    let server = FakeServer([(200, xstsAnswer), (200, xstsAnswer)])
    let key = ProofKey()

    _ = try await auth(server).userToken(accessToken: "the-access-token", key: key)
    _ = try await auth(server).userToken(accessToken: "the-access-token", key: nil)

    let (signed, unsigned) = (server.requests[0], server.requests[1])
    #expect(signed.url == URL(string: "https://user.auth.xboxlive.com/user/authenticate"))
    #expect(try signatureHolds(signed, path: "/user/authenticate", key: key))
    let properties = try #require(try json(signed)["Properties"] as? [String: Any])
    #expect(properties["RpsTicket"] as? String == "t=the-access-token")
    #expect(properties["ProofKey"] as? [String: String] == key.jwk)

    #expect(unsigned.value(forHTTPHeaderField: "Signature") == nil)
    #expect(try (json(unsigned)["Properties"] as? [String: Any])?["ProofKey"] == nil)
}

@Test func anXSTSTokenNamesItsRelyingPartyAsTheTableSpellsIt() async throws {
    let server = FakeServer([(200, deviceAnswer), (200, xstsAnswer)])
    let key = ProofKey()
    let xbox = auth(server)
    let device = try await xbox.deviceToken(key: key, deviceID: UUID())
    let user = try #require(XboxToken(answer: Data(xstsAnswer.utf8)))

    _ = try await xbox.xstsToken(
        relyingParty: "http://playfab.xboxlive.com/", userToken: user, deviceToken: device, key: key
    )

    let request = server.requests[1]
    #expect(request.url == URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize"))
    #expect(try signatureHolds(request, path: "/xsts/authorize", key: key))
    let body = try json(request)
    #expect(body["RelyingParty"] as? String == "http://playfab.xboxlive.com/")
    let properties = try #require(body["Properties"] as? [String: Any])
    #expect(properties["SandboxId"] as? String == "RETAIL")
    #expect(properties["UserTokens"] as? [String] == ["the-xsts-token"])
    #expect(properties["DeviceToken"] as? String == "the-device-token")
    #expect(properties["TitleToken"] == nil)
}

@Test func anXSTSAnswerIsRead() throws {
    let full = try #require(XboxToken(answer: Data(xstsAnswer.utf8)))
    #expect(full.user == XboxUser(
        userHash: "1283950176146904870",
        xuid: "2814630418365389",
        gamertag: "Someone",
        ageGroup: "Adult",
        privileges: "190 191"
    ))
    #expect(full.notAfter.timeIntervalSince(full.issued) == 8 * 3600)
    #expect(abs(full.issued.timeIntervalSince1970 - 1_790_712_029.319) < 0.001)

    let bare = try #require(XboxToken(answer: Data("""
        {"IssueInstant":"2026-09-29T20:00:29Z","NotAfter":"2026-09-30T04:00:29Z","Token":"t",\
        "DisplayClaims":{"xui":[{"uhs":"42"}]}}
        """.utf8)))
    #expect(bare.user == XboxUser(userHash: "42", xuid: nil, gamertag: nil, ageGroup: nil, privileges: nil))
    #expect(bare.issued.timeIntervalSince1970 == 1_790_712_029)
}

@Test func anXErrBecomesASentence() async throws {
    let server = FakeServer([(401, """
        {"Identity":"0","XErr":2148916233,"Message":"",\
        "Redirect":"https://start.ui.xboxlive.com/CreateAccount"}
        """)])
    let user = try #require(XboxToken(answer: Data(xstsAnswer.utf8)))

    do {
        _ = try await auth(server).xstsToken(relyingParty: "http://xboxlive.com", userToken: user, key: nil)
        Issue.record("an XErr was not refused")
    } catch let error as XboxLiveError {
        #expect(error == .refused(
            status: 401, xerr: 0x8015_DC09, redirect: URL(string: "https://start.ui.xboxlive.com/CreateAccount")
        ))
        let sentence = try #require(error.errorDescription)
        #expect(sentence.contains("Account Creation Required"))
        #expect(sentence.contains("xbox.com"))
    }
}

// MARK: - The whole sign-in

private let userAnswer = """
    {"IssueInstant":"2026-09-29T20:00:29Z","NotAfter":"2026-10-03T20:00:29Z","Token":"the-user-token",\
    "DisplayClaims":{"xui":[{"uhs":"1283950176146904870"}]}}
    """

private let playfabAnswer = """
    {"IssueInstant":"2026-09-29T20:00:29Z","NotAfter":"2026-09-30T12:00:29Z","Token":"the-playfab-token",\
    "DisplayClaims":{"xui":[{"uhs":"1283950176146904870"}]}}
    """

private func events(_ stream: AsyncStream<SignInEvent>) async -> [SignInEvent] {
    var all: [SignInEvent] = []
    for await event in stream { all.append(event) }
    return all
}

private func xboxSignIn(
    _ server: FakeServer,
    relyingParties: [RelyingParty] = [RelyingParty("http://playfab.xboxlive.com/", hosts: ["playfabapi.com"])],
    device: XboxDevice? = nil
) -> XboxSignIn {
    XboxSignIn(
        clientID: "0000000012345678",
        relyingParties: relyingParties,
        device: device,
        transport: server.transport,
        sleep: { _ in },
        now: { now }
    )
}

@Test func aFirstSignInShowsACodeAndBindsNothing() async throws {
    let server = FakeServer([
        (200, codeAnswer), (200, tokenAnswer), (200, userAnswer), (200, xstsAnswer), (200, playfabAnswer),
    ])

    let all = await events(xboxSignIn(server).run())

    guard all.count == 3, case .code(let code) = all[0], case .signedIn(let result) = all[1] else {
        Issue.record("the sign-in went \(all)")
        return
    }
    #expect(all[2] == .finished)
    #expect(code.userCode == "ABCD1234")
    #expect(result.refreshToken == "the-refresh-token")
    #expect(result.session.user.xuid == "2814630418365389")
    #expect(Set(result.session.tokens.keys) == ["http://xboxlive.com", "http://playfab.xboxlive.com/"])
    #expect(result.session.tokens["http://playfab.xboxlive.com/"]?.token == "the-playfab-token")
    #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Signature") == nil })
    #expect(!server.requests.contains { $0.url?.host() == "device.auth.xboxlive.com" })
}

@Test func aRefreshTokenSignsInAgainWithoutACodeAndTheDeviceBindsOnlyWhatWantsIt() async throws {
    let server = FakeServer([
        (200, tokenAnswer), (200, userAnswer), (200, deviceAnswer),
        (200, xstsAnswer), (200, playfabAnswer),
    ])
    let device = XboxDevice(key: ProofKey(), id: UUID())

    let signIn = xboxSignIn(server, relyingParties: [.playFab], device: device)
    let all = await events(signIn.run(refreshToken: "an-old-refresh-token"))

    guard all.count == 2, case .signedIn(let result) = all[0] else {
        Issue.record("the sign-in went \(all)")
        return
    }
    #expect(result.refreshToken == "the-refresh-token")

    let users = server.requests.filter { $0.url?.host() == "user.auth.xboxlive.com" }
    #expect(users.count == 1)
    #expect(users.first?.value(forHTTPHeaderField: "Signature") == nil)

    let xsts = server.requests.filter { $0.url?.host() == "xsts.auth.xboxlive.com" }
    #expect(try xsts.map { try json($0)["RelyingParty"] as? String } == [
        "http://xboxlive.com", "http://playfab.xboxlive.com/",
    ])
    let identity = try #require(try json(xsts[0])["Properties"] as? [String: Any])
    #expect(identity["UserTokens"] as? [String] == ["the-user-token"])
    #expect(identity["DeviceToken"] == nil)
    #expect(xsts[0].value(forHTTPHeaderField: "Signature") == nil)
    let playFab = try #require(try json(xsts[1])["Properties"] as? [String: Any])
    #expect(playFab["UserTokens"] as? [String] == ["the-user-token"])
    #expect(playFab["DeviceToken"] as? String == "the-device-token")
    #expect(try signatureHolds(xsts[1], path: "/xsts/authorize", key: device.key))
}

@Test func aRefreshTokenMicrosoftRefusesFallsBackToACode() async throws {
    let server = FakeServer([
        (400, #"{"error":"invalid_grant","error_description":"The refresh token has expired."}"#),
        (200, codeAnswer), (200, tokenAnswer), (200, userAnswer), (200, xstsAnswer), (200, playfabAnswer),
    ])

    let all = await events(xboxSignIn(server).run(refreshToken: "a-lapsed-refresh-token"))

    #expect(all.count == 3)
    guard case .code = all.first, case .signedIn = all.dropFirst().first else {
        Issue.record("the sign-in went \(all)")
        return
    }
}

@Test func anAccountXboxLiveRefusesEndsWithItsReason() async throws {
    let server = FakeServer([(200, tokenAnswer), (200, userAnswer), (401, #"{"XErr":2148916238}"#)])

    let all = await events(xboxSignIn(server).run(refreshToken: "a-refresh-token"))

    guard all.count == 2, case .failed(let reason) = all[0] else {
        Issue.record("the sign-in went \(all)")
        return
    }
    #expect(reason.contains("Child not in Family"))
    #expect(all[1] == .finished)
}

// MARK: - Answering a title's runtime

private func temporaryPaths() -> Paths {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-sign-in-\(UUID().uuidString)")
    return Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
}

private func remove(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
}

/// A bottle with a GDK title installed and its runtime's request waiting in the mailbox.
private func titleAsking(in paths: Paths, titleID: String = "12AB34CD") throws -> GDKMailbox.Request {
    let bottle = Bottle(paths: paths, name: "gdk")
    let game = bottle.driveC.appending(path: "Program Files/Example")
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    try Data("""
        <Game><ShellVisuals DefaultDisplayName="Example Game" /><TitleId>12AB34CD</TitleId>\
        <MSAAppId>0000000012345678</MSAAppId></Game>
        """.utf8).write(to: game.appending(path: GDKTitle.configName))

    let folder = GDKMailbox(bottle: bottle).directory.appending(path: titleID)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let id = "{\(UUID().uuidString)}"
    try Data("sake 1\nrequest \(id)\n".utf8).write(to: folder.appending(path: "request"))
    return GDKMailbox.Request(bottle: "gdk", titleID: titleID, id: id)
}

private func mailboxFile(_ name: String, _ request: GDKMailbox.Request, in paths: Paths) -> URL {
    GDKMailbox(bottle: Bottle(paths: paths, name: request.bottle)).directory
        .appending(path: "\(request.titleID)/\(name)")
}

private func answer(to request: GDKMailbox.Request, in paths: Paths) -> [String: String]? {
    GDKMailbox.read(mailboxFile("answer", request, in: paths))
}

private func events(_ stream: AsyncStream<GDKSignInEvent>) async -> [GDKSignInEvent] {
    var all: [GDKSignInEvent] = []
    for await event in stream { all.append(event) }
    return all
}

private func gdkSignIn(_ request: GDKMailbox.Request, _ paths: Paths, _ server: FakeServer) -> GDKSignIn {
    GDKSignIn(request: request, paths: paths, transport: server.transport, sleep: { _ in }, now: { now })
}

private func permissions(of url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}

@Test func aTitlesFirstRequestShowsACodeAndIsAnsweredWithASession() async throws {
    let paths = temporaryPaths()
    defer { remove(paths) }
    let request = try titleAsking(in: paths)
    let server = FakeServer([
        (200, codeAnswer), (200, tokenAnswer), (200, userAnswer), (200, deviceAnswer),
        (200, xstsAnswer), (200, playfabAnswer),
    ])

    let all = await events(gdkSignIn(request, paths, server).run())

    guard all.count == 3, case .code(let code, let title) = all[0] else {
        Issue.record("the sign-in went \(all)")
        return
    }
    #expect(code.userCode == "ABCD1234")
    #expect(title == "Example Game")
    #expect(Array(all.dropFirst()) == [.signedIn(title: "Example Game"), .finished])
    #expect(form(try #require(server.requests.first))["client_id"] == "0000000012345678")

    #expect(answer(to: request, in: paths) == ["request": request.id, "state": "signed-in"])
    #expect(!FileManager.default.fileExists(atPath: mailboxFile("request", request, in: paths).path))
    let session = mailboxFile("session", request, in: paths)
    let lines = try String(contentsOf: session, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.contains("xuid 2814630418365389"))
    #expect(lines.contains("endpoint playfabapi.com http://playfab.xboxlive.com/"))
    #expect(lines.contains("endpoint xboxlive.com http://xboxlive.com"))
    #expect(lines.contains { $0.hasPrefix("token http://playfab.xboxlive.com/ ") && $0.hasSuffix(" the-playfab-token") })
    #expect(try permissions(of: session) == 0o600)

    let kept = try #require(XboxAccounts(paths: paths).account(for: "0000000012345678"))
    #expect(kept.refreshToken == "the-refresh-token")
    let device = try #require(server.requests.first { $0.url?.host() == "device.auth.xboxlive.com" })
    #expect(try (json(device)["Properties"] as? [String: Any])?["Id"] as? String == "{\(kept.deviceID.uuidString)}")
    #expect(try permissions(of: paths.signIns) == 0o700)
    #expect(try permissions(of: paths.signIns.appending(path: "0000000012345678.json")) == 0o600)
}

@Test func aKeptSignInAnswersWithoutACodeAndKeepsItsDevice() async throws {
    let paths = temporaryPaths()
    defer { remove(paths) }
    let request = try titleAsking(in: paths)
    let device = XboxDevice(key: ProofKey(), id: UUID())
    try XboxAccounts(paths: paths).save(
        XboxAccount(refreshToken: "an-old-refresh-token", device: device), for: "0000000012345678"
    )
    let server = FakeServer([
        (200, tokenAnswer), (200, userAnswer), (200, deviceAnswer),
        (200, xstsAnswer), (200, playfabAnswer),
    ])

    let all = await events(gdkSignIn(request, paths, server).run())

    #expect(all == [.signedIn(title: "Example Game"), .finished])
    #expect(form(try #require(server.requests.first))["refresh_token"] == "an-old-refresh-token")
    let xsts = try #require(server.requests.last)
    #expect(try signatureHolds(xsts, path: "/xsts/authorize", key: device.key))
    let kept = try #require(XboxAccounts(paths: paths).account(for: "0000000012345678"))
    #expect(kept.refreshToken == "the-refresh-token")
    #expect(kept.deviceID == device.id)
    #expect(kept.deviceKey == device.key.rawRepresentation)
}

@Test func aRequestForATitleTheBottleDoesNotHaveIsRefused() async throws {
    let paths = temporaryPaths()
    defer { remove(paths) }
    let request = try titleAsking(in: paths, titleID: "0BADF00D")
    let server = FakeServer([])

    let all = await events(gdkSignIn(request, paths, server).run())

    guard all.count == 2, case .failed(let reason, nil) = all[0] else {
        Issue.record("the sign-in went \(all)")
        return
    }
    #expect(reason.contains("0BADF00D"))
    #expect(answer(to: request, in: paths)?["state"] == "failed")
    #expect(server.requests.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: mailboxFile("request", request, in: paths).path))
}

@Test func aSignInXboxLiveRefusesIsAnsweredWithItsReason() async throws {
    let paths = temporaryPaths()
    defer { remove(paths) }
    let request = try titleAsking(in: paths)
    try XboxAccounts(paths: paths).save(
        XboxAccount(refreshToken: "a-refresh-token", device: XboxDevice(key: ProofKey(), id: UUID())),
        for: "0000000012345678"
    )
    let server = FakeServer([
        (200, tokenAnswer), (200, userAnswer), (200, deviceAnswer),
        (401, #"{"XErr":2148916238}"#),
    ])

    let all = await events(gdkSignIn(request, paths, server).run())

    guard all.count == 2, case .failed(let reason, "Example Game") = all[0] else {
        Issue.record("the sign-in went \(all)")
        return
    }
    #expect(reason.contains("Child not in Family"))
    let answered = try #require(answer(to: request, in: paths))
    #expect(answered["state"] == "failed")
    #expect(answered["reason"]?.contains("Child not in Family") == true)
    #expect(!FileManager.default.fileExists(atPath: mailboxFile("session", request, in: paths).path))
}

@Test func aSignInNobodyReadsAnyMoreIsAnsweredCancelled() async throws {
    let paths = temporaryPaths()
    defer { remove(paths) }
    let request = try titleAsking(in: paths)
    let server = FakeServer([(200, codeAnswer)])
    let signIn = GDKSignIn(
        request: request, paths: paths, transport: server.transport,
        sleep: { _ in try await Task.sleep(for: .seconds(60)) }, now: { now }
    )

    let reading = Task { await events(signIn.run()) }
    while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(answer(to: request, in: paths)?["state"] == "waiting")
    reading.cancel()
    _ = await reading.value

    let deadline = Date().addingTimeInterval(5)
    while answer(to: request, in: paths)?["state"] == "waiting", Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(answer(to: request, in: paths) == ["request": request.id, "state": "cancelled"])
    #expect(!FileManager.default.fileExists(atPath: mailboxFile("request", request, in: paths).path))
}
