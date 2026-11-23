import JWTKit

/// The claims we read from a Supabase access token. Field names and types are
/// from Supabase's "JWT Claims Reference" (checked 2026-11-24).
struct SupabaseClaims: JWTPayload {
    let sub: SubjectClaim
    let aud: AudienceClaim
    let iss: IssuerClaim
    let exp: ExpirationClaim
    let nbf: NotBeforeClaim?
    let role: String?
    let isAnonymous: Bool?

    enum CodingKeys: String, CodingKey {
        case sub, aud, iss, exp, nbf, role
        case isAnonymous = "is_anonymous"
    }

    /// Intentionally empty. Time and audience checks run in `TokenVerifier`,
    /// which has an injectable clock and the configuration.
    func verify(using algorithm: some JWTAlgorithm) async throws {}
}
