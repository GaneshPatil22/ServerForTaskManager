import BrainCore
import Foundation
import Logging
import Storage

/// One migrated database shared by every test in the process. Every test
/// target uses this one, because they run in the same process and two
/// separate resets would wipe the schema under each other.
///
/// Each test creates its own random users, so tests never see each other's rows.
public enum TestDatabase {
    static let ready = Task<Database, any Error> {
        var logger = Logger(label: "tests")
        logger.logLevel = .warning
        let env = ProcessInfo.processInfo.environment
        let config = DatabaseConfiguration(
            host: env["DATABASE_HOST"] ?? "127.0.0.1",
            port: env["DATABASE_PORT"].flatMap(Int.init) ?? 54329,
            username: env["DATABASE_USER"] ?? "brain",
            password: env["DATABASE_PASSWORD"] ?? "brain",
            database: env["DATABASE_NAME"] ?? "brain_test")
        let db = Database(configuration: config, logger: logger)
        Task { await db.run() }
        try await db.resetForTests()
        return db
    }

    public static func get() async throws -> Database { try await ready.value }

    /// A fresh user that already exists in `users`.
    public static func newUser() async throws -> UserStore {
        let store = try await get().scoped(to: UserID(UUID()))
        try await store.ensureUser()
        return store
    }
}

public func newID() -> ULID {
    ULID(
        timestampMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000),
        randomness: (0..<10).map { _ in UInt8.random(in: 0...255) })
}
