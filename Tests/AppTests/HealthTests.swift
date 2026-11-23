import BrainCore
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing
import TestDatabase

@testable import App

struct TestArguments: AppArguments {
    let hostname = "127.0.0.1"
    let port = 0
    let logLevel: Logger.Level? = .warning
}

/// The real router, on the test database, with a fake token verifier.
func testApp(clock: @escaping @Sendable () -> Date = { Date() }) async throws
    -> some ApplicationProtocol
{
    let deps = Dependencies(
        database: try await TestDatabase.get(), verifier: FakeVerifier(), clock: clock)
    return Application(router: try buildRouter(deps))
}

@Test func healthReturnsOKWithoutAToken() async throws {
    try await testApp().test(.router) { client in
        try await client.execute(uri: "/health", method: .get) { response in
            #expect(response.status == .ok)
        }
    }
}

@Test func unknownRouteIsNotFound() async throws {
    try await testApp().test(.router) { client in
        try await client.execute(
            uri: "/nope", method: .get,
            headers: [.authorization: "Bearer good-\(UUID().uuidString)"]
        ) { response in
            #expect(response.status == .notFound)
        }
    }
}

/// Proves the server links against Brain at the pinned version.
@Test func linksAgainstBrain() {
    #expect(ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV") != nil)
    #expect(ULID("not-a-ulid") == nil)
}
