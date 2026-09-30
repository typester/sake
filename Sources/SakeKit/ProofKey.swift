import CryptoKit
import Foundation

/// The key Xbox Live binds a sign-in's tokens to, and the `Signature` header every request
/// made with them carries. The header's layout is Microsoft's, from "Title service calls to
/// Xbox services" in the GDK documentation. See docs/gdk.md.
public struct ProofKey: Sendable {
    let key: P256.Signing.PrivateKey

    public init() {
        key = P256.Signing.PrivateKey()
    }

    public init(rawRepresentation: Data) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { key.rawRepresentation }

    public var jwk: [String: String] {
        let point = key.publicKey.x963Representation
        return [
            "alg": "ES256",
            "crv": "P-256",
            "kty": "EC",
            "use": "sig",
            "x": Self.base64URL(point[1..<33]),
            "y": Self.base64URL(point[33..<65]),
        ]
    }

    static let policyVersion: UInt32 = 1

    /// Signs `request` as it stands, so its body and `Authorization` must be final: the
    /// service checks the signature against the bytes it received.
    public func signature(for request: URLRequest, at date: Date, maxBodyBytes: Int = .max) throws -> String {
        let time = Self.fileTime(date)
        var message = Data()
        message.appendBigEndian(Self.policyVersion)
        message.append(0)
        message.appendBigEndian(time)
        message.append(0)
        message.append(contentsOf: (request.httpMethod ?? "GET").uppercased().utf8)
        message.append(0)
        message.append(contentsOf: Self.pathAndQuery(of: request.url).utf8)
        message.append(0)
        message.append(contentsOf: (request.value(forHTTPHeaderField: "Authorization") ?? "").utf8)
        message.append(0)
        message.append((request.httpBody ?? Data()).prefix(maxBodyBytes))
        message.append(0)

        var header = Data()
        header.appendBigEndian(Self.policyVersion)
        header.appendBigEndian(time)
        header.append(try key.signature(for: message).rawRepresentation)
        return header.base64EncodedString()
    }

    /// What goes on the request line, still percent-encoded. `URL.path` decodes and drops a
    /// trailing slash, so a signature made from it does not match what was sent.
    static func pathAndQuery(of url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return "/"
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard let query = components.percentEncodedQuery else { return path }
        return "\(path)?\(query)"
    }

    /// Windows file time: 100-nanosecond intervals since 1601.
    static func fileTime(_ date: Date) -> UInt64 {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        let ticks = UInt64((seconds - whole) * 10_000_000)
        return UInt64(Int64(whole) + 11_644_473_600) * 10_000_000 + ticks
    }

    static func base64URL(_ bytes: some DataProtocol) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
