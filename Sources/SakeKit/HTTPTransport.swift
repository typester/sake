import Foundation

/// Sends one request and hands back what came back, whatever its status. login.live.com says
/// "not yet" with a 400, so what a status means is the caller's to decide.
public struct HTTPTransport: Sendable {
    let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(_ send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.send = send
    }

    /// A session of its own that keeps nothing on disk. `SourceFetcher`'s default session is
    /// what left `~/Library/HTTPStorages/dev.typester.sake` outside both of sake's
    /// directories, and a sign-in's cookies would be Microsoft's.
    public static func ephemeral() -> HTTPTransport {
        let session = URLSession(configuration: .ephemeral)
        return HTTPTransport { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }
}
