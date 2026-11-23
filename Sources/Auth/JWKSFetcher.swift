import AsyncHTTPClient
import Foundation
import NIOCore

/// Where the public keys come from. Production fetches over HTTPS; tests
/// supply keys in memory and can rotate, revoke or fail on demand.
public protocol JWKSFetching: Sendable {
    func fetchJWKS() async throws -> Data
}

public struct HTTPJWKSFetcher: JWKSFetching {
    let url: String
    let client: HTTPClient

    public init(url: String, client: HTTPClient = .shared) {
        self.url = url
        self.client = client
    }

    public enum FetchError: Error { case status(UInt) }

    public func fetchJWKS() async throws -> Data {
        let response = try await client.execute(
            HTTPClientRequest(url: url), deadline: .now() + .seconds(5))
        guard response.status == .ok else { throw FetchError.status(response.status.code) }
        // A JWKS is a few hundred bytes; 1 MB is a guard, not an expectation.
        let body = try await response.body.collect(upTo: 1 << 20)
        return Data(body.readableBytesView)
    }
}
