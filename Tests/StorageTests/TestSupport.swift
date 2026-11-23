import BrainCore
import Foundation
import Logging
import PostgresNIO
import Testing

@testable import Storage

/// One migrated database shared by every test in the process. Each test
/// creates its own random users, so tests never see each other's rows.
enum TestDatabase {
    static let ready = Task<Database, any Error> {
        var logger = Logger(label: "storage-tests")
        logger.logLevel = .warning
        let env = ProcessInfo.processInfo.environment
        let config = DatabaseConfiguration(
            host: env["DATABASE_HOST"] ?? "127.0.0.1",
            port: env["DATABASE_PORT"].flatMap(Int.init) ?? 54329,
            username: env["DATABASE_USER"] ?? "brain",
            password: env["DATABASE_PASSWORD"] ?? "brain",
            database: env["DATABASE_NAME"] ?? "brain_test")
        // Wiping the schema is only ever allowed on a database named *_test.
        precondition(config.database.hasSuffix("_test"), "tests must use a *_test database")

        let db = Database(configuration: config, logger: logger)
        Task { await db.run() }
        // Start from nothing every run, so the migration itself is tested too.
        try await db.client.query("DROP SCHEMA public CASCADE")
        try await db.client.query("CREATE SCHEMA public")
        try await db.migrate()
        return db
    }

    static func get() async throws -> Database { try await ready.value }

    /// A fresh user that already exists in `users`.
    static func newUser() async throws -> UserStore {
        let store = try await get().scoped(to: UserID(UUID()))
        try await store.ensureUser()
        return store
    }
}

func newID() -> ULID {
    ULID(
        timestampMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000),
        randomness: (0..<10).map { _ in UInt8.random(in: 0...255) })
}

/// Whole seconds, so a value survives the round trip through `timestamptz`
/// (microsecond precision) and compares equal.
let fixedDate = Date(timeIntervalSince1970: 1_795_000_000)

/// Runs `body` and requires it to fail with this Postgres SQLSTATE.
/// 23503 foreign key, 23514 check, 23505 unique, P0001 raised by a trigger.
func expectSQLState(
    _ state: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("expected SQLSTATE \(state), but it succeeded", sourceLocation: sourceLocation)
    } catch let error as PSQLError {
        #expect(error.serverInfo?[.sqlState] == state, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected PSQLError, got \(error)", sourceLocation: sourceLocation)
    }
}

/// A user's full set of rows: one of everything, linked together.
struct Seed {
    let capture: Capture
    let goal: Goal
    let item: Item
    let other: Item
    let edge: Edge
    let correction: Correction

    static func insert(into store: UserStore) async throws -> Seed {
        let capture = Capture(id: newID(), rawText: "call bank re 50K loan", createdAt: fixedDate)
        let goal = Goal(id: newID(), title: "sort out finances", createdAt: fixedDate)
        let item = Item(
            id: newID(), captureId: capture.id, title: "call bank",
            type: Classified(.task, confidence: 0.9, tier: .t0, evidence: Span(start: 0, end: 4)),
            effort: Classified(.small, confidence: 0.6, tier: .t2),
            dueAt: Classified(
                fixedDate, confidence: 1, tier: .t0, evidence: Span(start: 5, end: 9)),
            goalId: Classified(goal.id, confidence: 1, tier: .user),
            category: Classified(.communication, confidence: 0.8, tier: .t0),
            createdAt: fixedDate)
        let other = Item(
            id: newID(), captureId: capture.id, title: "get loan", createdAt: fixedDate)
        let edge = Edge(id: newID(), from: item.id, to: other.id, kind: .blocks, source: .t0Rule)
        let correction = Correction(
            id: newID(), targetId: item.id, field: "effort", beforeValue: "small",
            afterValue: "medium", tier: .t2, createdAt: fixedDate)

        _ = try await store.insertCapture(capture)
        try await store.insertGoal(goal)
        try await store.insertItem(item)
        try await store.insertItem(other)
        try await store.insertEdge(edge)
        try await store.insertCorrection(correction)
        return Seed(
            capture: capture, goal: goal, item: item, other: other, edge: edge,
            correction: correction)
    }
}
