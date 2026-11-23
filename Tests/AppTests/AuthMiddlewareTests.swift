import Auth
import Foundation
import Hummingbird
import HummingbirdTesting
import Storage
import Testing

@testable import App

/// Accepts "good-<uuid>", throws the matching error for the others.
struct FakeVerifier: TokenVerifying {
    func verify(_ token: String) async throws -> UserID {
        if token.hasPrefix("good-"), let uuid = UUID(uuidString: String(token.dropFirst(5))) {
            return UserID(uuid)
        }
        if token == "keys-down" { throw AuthError.keysUnavailable }
        throw AuthError.invalidToken(reason: "fake")
    }
}

/// A router with one protected route that echoes the caller's user id.
func protectedApp() -> some ApplicationProtocol {
    let router = Router(context: AppRequestContext.self)
    router.group("v1").add(middleware: AuthMiddleware(verifier: FakeVerifier()))
        .get("whoami") { _, context in
            try context.requireUser().description
        }
    return Application(router: router)
}

@Suite("Auth middleware")
struct AuthMiddlewareTests {
    @Test func validTokenReachesTheRouteAsThatUser() async throws {
        let id = UUID()
        try await protectedApp().test(.router) { client in
            try await client.execute(
                uri: "/v1/whoami", method: .get,
                headers: [.authorization: "Bearer good-\(id.uuidString)"]
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == id.uuidString)
            }
        }
    }

    @Test func schemeIsCaseInsensitive() async throws {
        try await protectedApp().test(.router) { client in
            try await client.execute(
                uri: "/v1/whoami", method: .get,
                headers: [.authorization: "bearer good-\(UUID().uuidString)"]
            ) { #expect($0.status == .ok) }
        }
    }

    @Test(arguments: [
        nil, "", "Bearer", "Bearer ", "Basic dXNlcjpwYXNz", "good-x", "Bearer bad-token",
    ])
    func missingMalformedOrRefusedIs401(_ header: String?) async throws {
        try await protectedApp().test(.router) { client in
            var headers: HTTPFields = [:]
            if let header { headers[.authorization] = header }
            try await client.execute(uri: "/v1/whoami", method: .get, headers: headers) {
                response in
                #expect(response.status == .unauthorized)
                #expect(response.headers[.wwwAuthenticate] == "Bearer")
            }
        }
    }

    @Test func keysUnavailableIs503() async throws {
        try await protectedApp().test(.router) { client in
            try await client.execute(
                uri: "/v1/whoami", method: .get, headers: [.authorization: "Bearer keys-down"]
            ) { #expect($0.status == .serviceUnavailable) }
        }
    }

    @Test func apiRoutesNeedAToken() async throws {
        try await testApp().test(.router) { client in
            try await client.execute(uri: "/v1/captures", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
