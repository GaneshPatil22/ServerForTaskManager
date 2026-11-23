import Foundation
import JWTKit
import Logging
import Storage

public enum AuthError: Error, Equatable {
    /// 401. The reason is for logs only; clients get no detail.
    case invalidToken(reason: String)
    /// 503. We could not get Supabase's keys. Not the client's fault, and a
    /// 401 here would make apps log the user out.
    case keysUnavailable
}

/// Turns a Supabase access token into a `UserID`, or refuses it (ADR-0007).
///
/// Checks, in order: the header names ES256 or RS256 and a `kid` (HS256 and
/// `none` are refused before any key is touched); the `kid` is in the current
/// JWKS, refetching once if not; the key's own algorithm matches the header;
/// the signature; then `iss`, `aud`, `exp`, `nbf`, `role`, `is_anonymous`,
/// and that `sub` is a UUID.
///
/// The `kid` check is ours, not jwt-kit's: when a kid is unknown, jwt-kit
/// 5.9.1 falls back to its default key rather than failing
/// (`JWTKeyCollection.getSigner`), so it cannot tell us when to refetch.
public actor TokenVerifier {
    static let allowedAlgorithms: Set<String> = ["ES256", "RS256"]

    struct KeySet {
        let collection: JWTKeyCollection
        /// kid → the algorithm that key verifies.
        let algorithms: [String: String]
        let fetchedAt: Date
    }

    let configuration: AuthConfiguration
    let fetcher: any JWKSFetching
    let clock: @Sendable () -> Date
    let logger: Logger

    private var keys: KeySet?
    private var lastFetchAttempt: Date?
    private var inFlight: Task<KeySet, any Error>?
    /// Exposed for tests: how many times the JWKS was requested.
    private(set) var fetchCount = 0

    public init(
        configuration: AuthConfiguration, fetcher: any JWKSFetching,
        logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.fetcher = fetcher
        self.logger = logger
        self.clock = clock
    }

    public func verify(_ token: String) async throws -> UserID {
        let header = try Self.header(of: token)
        guard Self.allowedAlgorithms.contains(header.alg) else {
            throw AuthError.invalidToken(reason: "algorithm \(header.alg) not allowed")
        }
        guard let kid = header.kid else { throw AuthError.invalidToken(reason: "no kid") }

        let keys = try await keys(containing: kid)
        guard let keyAlgorithm = keys.algorithms[kid] else {
            throw AuthError.invalidToken(reason: "unknown kid")
        }
        guard keyAlgorithm == header.alg else {
            throw AuthError.invalidToken(
                reason: "header says \(header.alg), key is \(keyAlgorithm)")
        }

        let claims: SupabaseClaims
        do {
            claims = try await keys.collection.verify(token, as: SupabaseClaims.self)
        } catch {
            throw AuthError.invalidToken(reason: "signature or payload: \(error)")
        }
        return try check(claims)
    }

    func check(_ claims: SupabaseClaims) throws -> UserID {
        let now = clock()
        guard claims.iss.value == configuration.issuer else {
            throw AuthError.invalidToken(reason: "issuer")
        }
        guard claims.aud.value.contains(configuration.audience) else {
            throw AuthError.invalidToken(reason: "audience")
        }
        guard claims.exp.value.addingTimeInterval(configuration.leeway) > now else {
            throw AuthError.invalidToken(reason: "expired")
        }
        if let nbf = claims.nbf, nbf.value.addingTimeInterval(-configuration.leeway) > now {
            throw AuthError.invalidToken(reason: "not yet valid")
        }
        guard claims.role == "authenticated" else {
            throw AuthError.invalidToken(reason: "role \(claims.role ?? "missing")")
        }
        if claims.isAnonymous == true, !configuration.allowAnonymous {
            throw AuthError.invalidToken(reason: "anonymous user")
        }
        guard let uuid = UUID(uuidString: claims.sub.value) else {
            throw AuthError.invalidToken(reason: "sub is not a UUID")
        }
        return UserID(uuid)
    }

    // MARK: - Keys

    /// Current keys, refreshed when older than the TTL or when `kid` is not in
    /// them. Refetches are rate-limited, and the last good keys stay usable up
    /// to `maxKeyAge` if Supabase cannot be reached.
    func keys(containing kid: String) async throws -> KeySet {
        let now = clock()
        if let keys, now.timeIntervalSince(keys.fetchedAt) < configuration.keyCacheTTL,
            keys.algorithms[kid] != nil
        {
            return keys
        }
        let mayFetch =
            lastFetchAttempt.map {
                now.timeIntervalSince($0) >= configuration.minRefetchInterval
            } ?? true
        // Joining a fetch already in flight costs nothing, so always allowed.
        if mayFetch || inFlight != nil {
            do {
                self.keys = try await refresh()
            } catch {
                logger.error("JWKS fetch failed: \(error)")
            }
        }
        guard let keys else { throw AuthError.keysUnavailable }
        if clock().timeIntervalSince(keys.fetchedAt) > configuration.maxKeyAge {
            throw AuthError.keysUnavailable
        }
        return keys
    }

    /// One fetch at a time: concurrent callers share it.
    private func refresh() async throws -> KeySet {
        if let inFlight { return try await inFlight.value }
        lastFetchAttempt = clock()
        fetchCount += 1
        let task = Task { [fetcher, clock, logger] in
            try await Self.load(try await fetcher.fetchJWKS(), at: clock(), logger: logger)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Keeps only keys we can use safely: a `kid`, EC P-256 or RSA, and an
    /// algorithm of ES256 or RS256 (stated by the key, or implied by its type).
    ///
    /// Each key is decoded on its own. jwt-kit's `JWKS` decoder rejects the
    /// whole set if any one key has a type it does not know (found by
    /// `unusableKeysInTheSetAreIgnored`), which would turn one odd key from
    /// Supabase into every login failing.
    static func load(_ data: Data, at date: Date, logger: Logger) async throws -> KeySet {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawKeys = object["keys"] as? [Any]
        else {
            throw AuthError.keysUnavailable
        }
        let collection = JWTKeyCollection()
        var algorithms: [String: String] = [:]
        for rawKey in rawKeys {
            guard JSONSerialization.isValidJSONObject(rawKey),
                let jwk = try? JSONDecoder().decode(
                    JWK.self, from: JSONSerialization.data(withJSONObject: rawKey)),
                let kid = jwk.keyIdentifier?.string
            else {
                logger.warning("ignoring a JWKS key that is malformed, unsupported or has no kid")
                continue
            }
            let implied: String?
            switch jwk.keyType {
            case .ecdsa where jwk.curve == .ecdsa(.p256): implied = "ES256"
            case .rsa: implied = "RS256"
            default: implied = nil
            }
            guard let implied, jwk.algorithm == nil || jwk.algorithm?.rawValue == implied else {
                logger.warning("ignoring JWKS key \(kid): unsupported type or algorithm")
                continue
            }
            do {
                try await collection.add(jwk: jwk)
            } catch {
                logger.warning("ignoring JWKS key \(kid): \(error)")
                continue
            }
            algorithms[kid] = implied
        }
        return KeySet(collection: collection, algorithms: algorithms, fetchedAt: date)
    }

    // MARK: - Header

    struct Header: Decodable {
        let alg: String
        let kid: String?
    }

    static func header(of token: String) throws -> Header {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = base64URLDecode(parts[0]),
            let header = try? JSONDecoder().decode(Header.self, from: data)
        else {
            throw AuthError.invalidToken(reason: "malformed")
        }
        return header
    }

    static func base64URLDecode(_ part: Substring) -> Data? {
        var base64 = part.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

/// What the HTTP layer needs. `TokenVerifier` is the real one; tests of the
/// middleware substitute a fake.
public protocol TokenVerifying: Sendable {
    func verify(_ token: String) async throws -> UserID
}

extension TokenVerifier: TokenVerifying {}
