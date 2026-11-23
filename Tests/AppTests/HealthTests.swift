import BrainCore
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import App

struct TestArguments: AppArguments {
    let hostname = "127.0.0.1"
    let port = 0
    let logLevel: Logger.Level? = .warning
}

@Test func healthReturnsOK() async throws {
    let app = try await buildApplication(TestArguments())
    try await app.test(.router) { client in
        try await client.execute(uri: "/health", method: .get) { response in
            #expect(response.status == .ok)
        }
    }
}

@Test func unknownRouteIsNotFound() async throws {
    let app = try await buildApplication(TestArguments())
    try await app.test(.router) { client in
        try await client.execute(uri: "/nope", method: .get) { response in
            #expect(response.status == .notFound)
        }
    }
}

/// Proves the server links against Brain at the pinned version. Capture IDs
/// will be client-generated ULIDs (S3), so this is the first Brain type we use.
@Test func linksAgainstBrain() {
    #expect(ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV") != nil)
    #expect(ULID("not-a-ulid") == nil)
}
