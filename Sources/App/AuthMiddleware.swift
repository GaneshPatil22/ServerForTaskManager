import Auth
import HTTPTypes
import Hummingbird
import Storage

struct AppRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    /// Set by `AuthMiddleware`. Routes behind it can rely on it being non-nil.
    var userID: UserID?

    init(source: Source) {
        self.coreContext = .init(source: source)
        self.userID = nil
    }

    /// For routes behind `AuthMiddleware`. Throws 401 rather than crashing if
    /// a route is ever mounted without it.
    func requireUser() throws -> UserID {
        guard let userID else { throw HTTPError(.unauthorized) }
        return userID
    }
}

/// Requires `Authorization: Bearer <Supabase access token>`.
///
/// - no or malformed header, or a token that fails any check → 401 with
///   `WWW-Authenticate: Bearer`, and no detail in the body
/// - Supabase's keys unreachable → 503, so apps do not log the user out
///
/// The token itself is never logged; only the reason it was refused.
struct AuthMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext
    let verifier: any TokenVerifying

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let token = Self.bearerToken(request.headers[.authorization]) else {
            throw Self.unauthorized
        }
        var context = context
        do {
            context.userID = try await verifier.verify(token)
        } catch AuthError.invalidToken(let reason) {
            context.logger.info("token refused", metadata: ["reason": .string(reason)])
            throw Self.unauthorized
        } catch AuthError.keysUnavailable {
            context.logger.error("token not checked: Supabase signing keys unavailable")
            throw HTTPError(.serviceUnavailable)
        }
        context.logger[metadataKey: "user"] = .string(context.userID!.description)
        return try await next(request, context)
    }

    static let unauthorized = HTTPError(
        .unauthorized, headers: [.wwwAuthenticate: "Bearer"])

    static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
