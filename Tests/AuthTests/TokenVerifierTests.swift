import Foundation
import JWTKit
import Storage
import Testing

@testable import Auth

/// Expects `verify` to refuse the token as invalid (a 401).
func expectRefused(
    _ verifier: TokenVerifier, _ token: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        let user = try await verifier.verify(token)
        Issue.record("accepted as \(user)", sourceLocation: sourceLocation)
    } catch AuthError.invalidToken {
        // expected
    } catch {
        Issue.record("expected invalidToken, got \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Accepting good tokens")
struct AcceptTests {
    @Test func es256TokenGivesItsUser() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        let sub = UUID()
        let user = try await verifier.verify(try await key.sign(TestClaims(sub: sub.uuidString)))
        #expect(user == UserID(sub))
    }

    @Test func rs256TokenGivesItsUser() async throws {
        let key = try await SigningKey.rs256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        let sub = UUID()
        let user = try await verifier.verify(try await key.sign(TestClaims(sub: sub.uuidString)))
        #expect(user == UserID(sub))
    }

    @Test func keysAreFetchedOnceAndCached() async throws {
        let key = try await SigningKey.es256()
        let clock = TestClock()
        let verifier = makeVerifier(FakeJWKS([key]), clock: clock)
        for _ in 0..<5 {
            _ = try await verifier.verify(try await key.sign(TestClaims()))
            clock.advance(60)
        }
        #expect(await verifier.fetchCount == 1)
    }

    @Test func smallClockSkewIsTolerated() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        // Expired 10s ago by our clock: within the 30s leeway.
        let token = try await key.sign(TestClaims(exp: start.timeIntervalSince1970 - 10))
        _ = try await verifier.verify(token)
    }
}

@Suite("Refusing bad tokens")
struct RefuseTests {
    @Test func expired() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        await expectRefused(
            verifier, try await key.sign(TestClaims(exp: start.timeIntervalSince1970 - 31)))
    }

    @Test func notYetValid() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        await expectRefused(
            verifier, try await key.sign(TestClaims(nbf: start.timeIntervalSince1970 + 120)))
    }

    @Test func anonKeyAudience() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        await expectRefused(
            verifier, try await key.sign(TestClaims(aud: ["anon"], role: "anon")))
    }

    @Test func otherProjectsIssuer() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        await expectRefused(
            verifier, try await key.sign(TestClaims(iss: "https://other.supabase.co/auth/v1")))
    }

    @Test func wrongRole() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        await expectRefused(verifier, try await key.sign(TestClaims(role: "service_role")))
        await expectRefused(verifier, try await key.sign(TestClaims(role: nil)))
    }

    @Test func anonymousUserUnlessAllowed() async throws {
        let key = try await SigningKey.es256()
        let token = try await key.sign(TestClaims(isAnonymous: true))
        await expectRefused(makeVerifier(FakeJWKS([key]), clock: TestClock()), token)
        let allowing = makeVerifier(FakeJWKS([key]), clock: TestClock()) {
            $0.allowAnonymous = true
        }
        _ = try await allowing.verify(token)
    }

    @Test func subjectNotAUUID() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        await expectRefused(verifier, try await key.sign(TestClaims(sub: "admin")))
    }

    @Test func garbage() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        for token in ["", "abc", "a.b", "a.b.c", "....", "eyJ.eyJ.sig"] {
            await expectRefused(verifier, token)
        }
    }

    /// An attacker with their own key, using the real key's `kid`.
    @Test func signedByAnotherKeyWithTheSameKid() async throws {
        let real = try await SigningKey.es256(kid: "k1")
        let forged = try await SigningKey.es256(kid: "k1")
        let verifier = makeVerifier(FakeJWKS([real]), clock: TestClock())
        await expectRefused(verifier, try await forged.sign(TestClaims()))
    }

    @Test func algNone() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        let token = try handMadeToken(
            header: ["alg": "none", "kid": key.kid], claims: TestClaims())
        await expectRefused(verifier, token)
    }

    /// The classic confusion attack: HS256, "keyed" with the public key.
    @Test func hs256IsRefusedBeforeAnyKeyIsTouched() async throws {
        let key = try await SigningKey.es256()
        let jwks = FakeJWKS([key])
        let verifier = makeVerifier(jwks, clock: TestClock())
        let hmac = JWTKeyCollection()
        let publicKeyBytes = try JSONSerialization.data(withJSONObject: key.publicJWK)
        await hmac.add(
            hmac: HMACKey(from: publicKeyBytes), digestAlgorithm: .sha256,
            kid: JWKIdentifier(string: key.kid))
        let token = try await hmac.sign(TestClaims(), kid: JWKIdentifier(string: key.kid))
        await expectRefused(verifier, token)
        #expect(await verifier.fetchCount == 0)
    }

    /// Header says RS256 but the kid is the ES256 key.
    @Test func headerAlgorithmMustMatchTheKey() async throws {
        let es = try await SigningKey.es256()
        let rs = try await SigningKey.rs256(kid: "rs")
        let verifier = makeVerifier(FakeJWKS([es]), clock: TestClock())
        let token = try await rs.sign(TestClaims())
        let parts = token.split(separator: ".")
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": es.kid])
        await expectRefused(verifier, "\(header.base64URL).\(parts[1]).\(parts[2])")
    }

    @Test func tokenWithoutKid() async throws {
        let key = try await SigningKey.es256()
        let verifier = makeVerifier(FakeJWKS([key]), clock: TestClock())
        let token = try await key.sign(TestClaims())
        let parts = token.split(separator: ".")
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256"])
        await expectRefused(verifier, "\(header.base64URL).\(parts[1]).\(parts[2])")
    }
}

@Suite("Key rotation, revocation and outages")
struct KeyLifecycleTests {
    @Test func rotatedInKeyIsPickedUpByRefetch() async throws {
        let old = try await SigningKey.es256()
        let new = try await SigningKey.es256()
        let jwks = FakeJWKS([old])
        let clock = TestClock()
        let verifier = makeVerifier(jwks, clock: clock)
        _ = try await verifier.verify(try await old.sign(TestClaims()))

        await jwks.publish([old, new])
        clock.advance(31)  // past the refetch rate limit, inside the cache TTL
        _ = try await verifier.verify(try await new.sign(TestClaims()))
        #expect(await verifier.fetchCount == 2)
    }

    @Test func unknownKidFloodCausesOneRefetch() async throws {
        let key = try await SigningKey.es256()
        let clock = TestClock()
        let verifier = makeVerifier(FakeJWKS([key]), clock: clock)
        _ = try await verifier.verify(try await key.sign(TestClaims()))
        clock.advance(31)
        for _ in 0..<20 {
            let stranger = try await SigningKey.es256()
            await expectRefused(verifier, try await stranger.sign(TestClaims()))
        }
        #expect(await verifier.fetchCount == 2)
    }

    @Test func revokedKeyStopsWorkingAfterTheCacheExpires() async throws {
        let revoked = try await SigningKey.es256()
        let current = try await SigningKey.es256()
        let jwks = FakeJWKS([revoked, current])
        let clock = TestClock()
        let verifier = makeVerifier(jwks, clock: clock)
        _ = try await verifier.verify(try await revoked.sign(TestClaims()))

        await jwks.publish([current])
        // Still inside the 10-minute cache: accepted. Supabase's own edge cache
        // behaves the same way, which is why its docs say to wait 20 minutes.
        clock.advance(300)
        _ = try await verifier.verify(try await revoked.sign(TestClaims()))

        clock.advance(301)
        await expectRefused(verifier, try await revoked.sign(TestClaims()))
        _ = try await verifier.verify(try await current.sign(TestClaims()))
    }

    @Test func noKeysAtAllIs503NotA401() async throws {
        let key = try await SigningKey.es256()
        let jwks = FakeJWKS([key])
        await jwks.setFailing(true)
        let verifier = makeVerifier(jwks, clock: TestClock())
        await #expect(throws: AuthError.keysUnavailable) {
            try await verifier.verify(try await key.sign(TestClaims()))
        }
    }

    @Test func outageUsesLastGoodKeysUpToAnHour() async throws {
        let key = try await SigningKey.es256()
        let jwks = FakeJWKS([key])
        let clock = TestClock()
        let verifier = makeVerifier(jwks, clock: clock)
        _ = try await verifier.verify(try await key.sign(TestClaims()))

        await jwks.setFailing(true)
        clock.advance(1800)  // cache expired, refetch fails: keep going
        var claims = TestClaims()
        claims.exp = clock.now.addingTimeInterval(3600).timeIntervalSince1970
        _ = try await verifier.verify(try await key.sign(claims))

        clock.advance(1801)  // keys now over an hour old: fail closed
        claims.exp = clock.now.addingTimeInterval(3600).timeIntervalSince1970
        await #expect(throws: AuthError.keysUnavailable) {
            try await verifier.verify(try await key.sign(claims))
        }
    }

    @Test func unusableKeysInTheSetAreIgnored() async throws {
        let good = try await SigningKey.es256()
        let jwks = FakeJWKS([good])
        await jwks.publish([good])
        // A symmetric key and a key with no kid, as a misconfigured project
        // might publish. Neither may be used, and neither breaks loading.
        let raw: [[String: String]] = [
            ["kty": "oct", "k": "c2VjcmV0", "kid": "hs", "alg": "HS256"],
            ["kty": "EC", "crv": "P-256", "x": good.publicJWK["x"]!, "y": good.publicJWK["y"]!],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: ["keys": raw + [good.publicJWK]])
        let set = try await TokenVerifier.load(
            data, at: start, logger: .init(label: "t"))
        #expect(set.algorithms == [good.kid: "ES256"])
    }
}

@Suite("Configuration")
struct ConfigurationTests {
    @Test func derivesIssuerAndJWKSFromSupabaseURL() throws {
        let config = try AuthConfiguration.fromEnvironment([
            "SUPABASE_URL": "https://abcd.supabase.co/"
        ])
        #expect(config.issuer == "https://abcd.supabase.co/auth/v1")
        #expect(config.jwksURL == "https://abcd.supabase.co/auth/v1/.well-known/jwks.json")
    }

    @Test func refusesPlainHTTPExceptLocalhost() throws {
        #expect(throws: AuthConfigurationError.insecure("http://abcd.supabase.co")) {
            try AuthConfiguration.fromEnvironment(["SUPABASE_URL": "http://abcd.supabase.co"])
        }
        _ = try AuthConfiguration.fromEnvironment(["SUPABASE_URL": "http://127.0.0.1:54321"])
        #expect(throws: AuthConfigurationError.missing("SUPABASE_URL")) {
            try AuthConfiguration.fromEnvironment([:])
        }
    }
}
