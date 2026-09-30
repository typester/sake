import Foundation

/// What sake keeps of a sign-in so that the person enters a code once rather than every time
/// a title's tokens run out.
public struct XboxAccount: Sendable, Equatable, Codable {
    public let refreshToken: String
    public let deviceID: UUID
    public let deviceKey: Data

    public init(refreshToken: String, device: XboxDevice) {
        self.refreshToken = refreshToken
        deviceID = device.id
        deviceKey = device.key.rawRepresentation
    }

    public func device() throws -> XboxDevice {
        XboxDevice(key: try ProofKey(rawRepresentation: deviceKey), id: deviceID)
    }
}

/// One file per OAuth client under ``Paths/signIns``, readable by the person alone.
///
/// A file rather than the Keychain: measured on 2026-09-29, an ad hoc signature has the
/// Keychain ask for the login password every time sake reads, Always Allow included. See
/// docs/gdk.md.
public struct XboxAccounts: Sendable {
    private let directory: URL

    public init(paths: Paths = .default) {
        directory = paths.signIns
    }

    public func account(for clientID: String) -> XboxAccount? {
        guard let file = file(for: clientID), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(XboxAccount.self, from: data)
    }

    public func save(_ account: XboxAccount, for clientID: String) throws {
        guard let file = file(for: clientID) else { throw XboxAccountsError.notAClientID(clientID) }
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(account).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The name comes from a config any program in the bottle can write, so it is a file
    /// name only when it is the 16 hexadecimal digits an `MSAAppId` is.
    private func file(for clientID: String) -> URL? {
        guard clientID.count == 16, clientID.allSatisfy(\.isHexDigit) else { return nil }
        return directory.appending(path: "\(clientID.uppercased()).json")
    }
}

public enum XboxAccountsError: Error, Equatable, LocalizedError {
    case notAClientID(String)

    public var errorDescription: String? {
        switch self {
        case .notAClientID(let id): "“\(id)” is not a Microsoft app ID"
        }
    }
}
