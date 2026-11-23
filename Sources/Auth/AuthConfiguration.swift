import Foundation

public struct AuthConfiguration: Sendable {
    /// `iss` every token must carry: `<SUPABASE_URL>/auth/v1`.
    public var issuer: String
    public var jwksURL: String
    /// Signed-in users get `authenticated`; the anon key gets `anon`.
    public var audience = "authenticated"
    /// Supabase anonymous sign-ins also carry `aud = authenticated`, marked by
    /// `is_anonymous`. Refused by default: an anonymous account costs nothing
    /// to create, and every capture can spend shared free-tier quota.
    public var allowAnonymous = false
    /// Supabase's edge caches the JWKS for 10 minutes and its docs say not to
    /// cache longer, or a revoked key keeps working.
    public var keyCacheTTL: TimeInterval = 600
    /// A token with an unknown `kid` triggers a refetch at most this often,
    /// so a flood of junk tokens cannot turn into a flood of JWKS requests.
    public var minRefetchInterval: TimeInterval = 30
    /// If Supabase is unreachable, keep using the last good keys for this
    /// long. Past it, fail closed with 503 rather than trust old keys forever.
    public var maxKeyAge: TimeInterval = 3600
    /// Tolerated clock difference between this server and Supabase.
    public var leeway: TimeInterval = 30

    public init(issuer: String, jwksURL: String) {
        self.issuer = issuer
        self.jwksURL = jwksURL
    }

    /// From `SUPABASE_URL`, e.g. `https://abcd.supabase.co`. Must be https,
    /// except a local Supabase on localhost.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        guard var base = env["SUPABASE_URL"], !base.isEmpty else {
            throw AuthConfigurationError.missing("SUPABASE_URL")
        }
        while base.hasSuffix("/") { base.removeLast() }
        let isLocal =
            base.hasPrefix("http://localhost") || base.hasPrefix("http://127.0.0.1")
        guard base.hasPrefix("https://") || isLocal else {
            throw AuthConfigurationError.insecure(base)
        }
        let issuer = base + "/auth/v1"
        return .init(issuer: issuer, jwksURL: issuer + "/.well-known/jwks.json")
    }
}

public enum AuthConfigurationError: Error, Equatable {
    case missing(String)
    case insecure(String)
}
