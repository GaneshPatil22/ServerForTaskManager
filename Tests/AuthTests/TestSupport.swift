import CryptoExtras
import Foundation
import JWTKit
import Logging
import Testing

@testable import Auth

let issuer = "https://test.supabase.co/auth/v1"
let start = Date(timeIntervalSince1970: 1_795_000_000)

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = start
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// Stands in for Supabase's JWKS endpoint.
actor FakeJWKS: JWKSFetching {
    var keys: [[String: String]]
    var failing = false
    init(_ keys: [SigningKey]) { self.keys = keys.map(\.publicJWK) }

    func publish(_ keys: [SigningKey]) { self.keys = keys.map(\.publicJWK) }
    func setFailing(_ value: Bool) { failing = value }

    struct Down: Error {}
    func fetchJWKS() async throws -> Data {
        if failing { throw Down() }
        return try JSONSerialization.data(withJSONObject: ["keys": keys])
    }
}

/// A private key that signs test tokens, and its public JWK as Supabase
/// would publish it.
struct SigningKey: Sendable {
    let kid: String
    let signer: JWTKeyCollection
    let publicJWK: [String: String]

    static func es256(kid: String = UUID().uuidString) async throws -> SigningKey {
        let key = ES256PrivateKey()
        let (x, y) = try #require(key.publicKey.parameters)
        let signer = JWTKeyCollection()
        await signer.add(ecdsa: key, kid: JWKIdentifier(string: kid))
        return SigningKey(
            kid: kid, signer: signer,
            publicJWK: [
                "kty": "EC", "crv": "P-256", "x": x, "y": y, "kid": kid, "alg": "ES256",
                "use": "sig",
            ])
    }

    static func rs256(kid: String = UUID().uuidString) async throws -> SigningKey {
        let key = try Insecure.RSA.PrivateKey(
            backing: _RSA.Signing.PrivateKey(keySize: .bits2048))
        let (n, e) = try key.publicKey.getKeyPrimitives()
        let signer = JWTKeyCollection()
        await signer.add(rsa: key, digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))
        return SigningKey(
            kid: kid, signer: signer,
            publicJWK: [
                "kty": "RSA", "n": n.base64URL, "e": e.base64URL, "kid": kid, "alg": "RS256",
                "use": "sig",
            ])
    }

    func sign(_ claims: TestClaims) async throws -> String {
        try await signer.sign(claims, kid: JWKIdentifier(string: kid))
    }
}

/// Supabase-shaped claims with every field adjustable.
struct TestClaims: JWTPayload {
    var sub = UUID().uuidString
    var aud: [String] = ["authenticated"]
    var iss = issuer
    var exp = start.addingTimeInterval(3600).timeIntervalSince1970
    var nbf: Double? = nil
    var role: String? = "authenticated"
    var isAnonymous: Bool? = false

    enum CodingKeys: String, CodingKey {
        case sub, aud, iss, exp, nbf, role
        case isAnonymous = "is_anonymous"
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {}
}

func makeVerifier(
    _ jwks: FakeJWKS, clock: TestClock, configure: (inout AuthConfiguration) -> Void = { _ in }
) -> TokenVerifier {
    var config = AuthConfiguration(
        issuer: issuer, jwksURL: "https://test.supabase.co/auth/v1/.well-known/jwks.json")
    configure(&config)
    return TokenVerifier(
        configuration: config, fetcher: jwks, logger: Logger(label: "auth-tests"),
        clock: { clock.now })
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A token whose header we write by hand: for `none` and HS256 attacks.
func handMadeToken(header: [String: String], claims: TestClaims, signature: String = "")
    throws -> String
{
    let h = try JSONSerialization.data(withJSONObject: header).base64URL
    let p = try JSONEncoder().encode(claims).base64URL
    return "\(h).\(p).\(signature)"
}
