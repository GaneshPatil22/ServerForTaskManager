import Foundation
import Testing

@testable import Storage

@Suite("Database configuration")
struct DatabaseConfigurationTests {
    let base = [
        "DATABASE_HOST": "aws-1-ap-south-1.pooler.supabase.com", "DATABASE_PORT": "5432",
        "DATABASE_USER": "postgres.abc", "DATABASE_PASSWORD": "x", "DATABASE_NAME": "postgres",
    ]

    @Test func tlsMustBeChosenExplicitly() {
        #expect(throws: StorageError.missingEnvironment("DATABASE_TLS")) {
            try DatabaseConfiguration.fromEnvironment(base)
        }
        var env = base
        env["DATABASE_TLS"] = "require"
        #expect(throws: StorageError.self) { try DatabaseConfiguration.fromEnvironment(env) }
    }

    @Test func verifyFullWithAndWithoutAPinnedCA() throws {
        var env = base
        env["DATABASE_TLS"] = "verify-full"
        #expect(try DatabaseConfiguration.fromEnvironment(env).tls == .verifyFull(caFile: nil))

        let ca = FileManager.default.temporaryDirectory.appendingPathComponent("ca-\(UUID()).crt")
        try "pem".write(to: ca, atomically: true, encoding: .utf8)
        env["DATABASE_CA_FILE"] = ca.path
        #expect(try DatabaseConfiguration.fromEnvironment(env).tls == .verifyFull(caFile: ca.path))

        env["DATABASE_CA_FILE"] = "/nonexistent/ca.crt"
        #expect(throws: StorageError.self) { try DatabaseConfiguration.fromEnvironment(env) }
    }

    @Test func disableIsAllowedForLocalDocker() throws {
        var env = base
        env["DATABASE_TLS"] = "disable"
        #expect(try DatabaseConfiguration.fromEnvironment(env).tls == .disabled)
    }
}
