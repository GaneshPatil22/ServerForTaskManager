import BrainCore
import Foundation
import Logging
import PostgresMigrations
import JobsPostgres
import NIOSSL
import PostgresNIO

/// A Supabase user id (`auth.users.id`). Every data access needs one.
public struct UserID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public enum StorageError: Error, Equatable {
    /// A stored value no longer parses into its Brain type. Means the schema
    /// and Brain have drifted; never expected in normal operation.
    case corruptRow(table: String, column: String, value: String)
    case missingEnvironment(String)
}

public struct DatabaseConfiguration: Sendable {
    /// How the connection is encrypted. There is deliberately no "encrypt but
    /// don't check who answers": that protects against nobody.
    public enum TLSMode: Sendable, Equatable {
        /// Local Docker only.
        case disabled
        /// Encrypted, with the server's certificate chain *and* hostname
        /// checked. Against `caFile` if given (Supabase publishes its own
        /// root certificate), otherwise the system's trusted roots.
        case verifyFull(caFile: String?)
    }

    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var database: String
    public var tls: TLSMode

    public init(
        host: String, port: Int, username: String, password: String, database: String,
        tls: TLSMode = .disabled
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
    }

    /// Reads `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`,
    /// `DATABASE_PASSWORD`, `DATABASE_NAME`, `DATABASE_TLS` (`disable` or
    /// `verify-full`) and optionally `DATABASE_CA_FILE`. No defaults: a missing
    /// value is an error, so production never silently connects somewhere
    /// local, or unencrypted.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        func require(_ key: String) throws -> String {
            guard let value = env[key], !value.isEmpty else {
                throw StorageError.missingEnvironment(key)
            }
            return value
        }
        let portString = try require("DATABASE_PORT")
        guard let port = Int(portString) else {
            throw StorageError.missingEnvironment("DATABASE_PORT (not a number)")
        }
        let tls: TLSMode
        switch try require("DATABASE_TLS") {
        case "disable":
            tls = .disabled
        case "verify-full":
            let caFile = env["DATABASE_CA_FILE"].flatMap { $0.isEmpty ? nil : $0 }
            if let caFile, !FileManager.default.isReadableFile(atPath: caFile) {
                throw StorageError.missingEnvironment("DATABASE_CA_FILE (cannot read \(caFile))")
            }
            tls = .verifyFull(caFile: caFile)
        case let other:
            throw StorageError.missingEnvironment(
                "DATABASE_TLS (\(other)): use disable or verify-full")
        }
        return .init(
            host: try require("DATABASE_HOST"), port: port,
            username: try require("DATABASE_USER"), password: try require("DATABASE_PASSWORD"),
            database: try require("DATABASE_NAME"), tls: tls)
    }

    var clientConfiguration: PostgresClient.Configuration {
        let tls: PostgresClient.Configuration.TLS
        switch self.tls {
        case .disabled:
            tls = .disable
        case .verifyFull(let caFile):
            var config = TLSConfiguration.makeClientConfiguration()
            config.certificateVerification = .fullVerification
            if let caFile { config.trustRoots = .file(caFile) }
            tls = .require(config)
        }
        return .init(
            host: host, port: port, username: username, password: password,
            database: database, tls: tls)
    }
}

/// The only way into the data. The Postgres client is internal to this
/// module, so code outside it cannot write a query at all: it has to ask for
/// `scoped(to:)` and gets a store that already carries the user's id.
public final class Database: Sendable {
    let client: PostgresClient
    let logger: Logger
    let name: String
    /// One list for every migration this database runs, ours and the job
    /// queue's, so a single `migrate()` applies all of them.
    let migrations = DatabaseMigrations()

    public init(configuration: DatabaseConfiguration, logger: Logger) {
        self.client = PostgresClient(
            configuration: configuration.clientConfiguration, backgroundLogger: logger)
        self.logger = logger
        self.name = configuration.database
    }

    /// Runs the connection pool. Must be running for any query to complete;
    /// returns when the surrounding task is cancelled.
    public func run() async {
        await client.run()
    }

    /// Applies every migration not yet applied, in one transaction. Create
    /// the job queue driver first, so its migrations are included.
    public func migrate() async throws {
        await migrations.add(M0001_CoreTables(), skipDuplicates: true)
        await migrations.add(M0002_BudgetCounters(), skipDuplicates: true)
        await migrations.add(M0003_CaptureProgress(), skipDuplicates: true)
        await migrations.add(M0004_RejectedLinks(), skipDuplicates: true)
        await migrations.add(M0005_Planner(), skipDuplicates: true)
        await migrations.add(M0006_Questions(), skipDuplicates: true)
        try await migrations.apply(client: client, logger: logger, dryRun: false)
    }

    /// The Postgres driver for swift-jobs, on this database's pool. Its tables
    /// live in their own `swift_jobs` schema, which Supabase's data API does
    /// not expose.
    public func makeJobQueueDriver(queueName: String = "default") async -> PostgresJobQueue {
        await PostgresJobQueue(
            client: client, migrations: migrations,
            configuration: .init(queueName: queueName), logger: logger)
    }

    // MARK: - Deployment-wide queries
    //
    // The two queries below read across users. They return ids and a count,
    // never content, and exist only for the enrichment sweeper. Everything
    // that returns a user's data goes through `UserStore`.

    /// Captures whose enrichment has not finished and that no item exists for:
    /// - `raw` for longer than `rawGrace` (its job was lost, or is very late)
    /// - `enriching` for longer than `stuckAfter` (the worker died mid-capture)
    /// - `failed` without an item (a retryable failure)
    /// Each is tried at most `maxAttempts` times, and is kept either way.
    public func capturesNeedingEnrichment(
        now: Date, rawGrace: TimeInterval, stuckAfter: TimeInterval, maxAttempts: Int,
        limit: Int
    ) async throws -> [(user: UserID, capture: ULID)] {
        let rawCutoff = now.addingTimeInterval(-rawGrace)
        let stuckCutoff = now.addingTimeInterval(-stuckAfter)
        let rows = try await client.query(
            """
            SELECT c.user_id, c.id FROM captures c
            WHERE c.status IN ('raw', 'enriching', 'failed')
              AND c.enrich_attempts < \(maxAttempts)
              AND (   (c.status = 'raw' AND c.status_changed_at < \(rawCutoff))
                   OR (c.status = 'enriching' AND c.status_changed_at < \(stuckCutoff))
                   OR  c.status = 'failed')
              AND NOT EXISTS (
                  SELECT 1 FROM items i WHERE i.user_id = c.user_id AND i.capture_id = c.id)
            ORDER BY c.status_changed_at
            LIMIT \(limit)
            """, logger: logger)
        var result: [(user: UserID, capture: ULID)] = []
        for try await (user, id) in rows.decode((UUID, String).self) {
            guard let ulid = ULID(id) else { continue }
            result.append((UserID(user), ulid))
        }
        return result
    }

    /// Users who captured anything since `since`. Sizes the per-user fair share.
    public func activeUsers(since: Date) async throws -> Int {
        let rows = try await client.query(
            "SELECT count(DISTINCT user_id)::bigint FROM captures WHERE created_at >= \(since)",
            logger: logger)
        for try await (count) in rows.decode(Int.self) { return count }
        return 0
    }

    /// Drops everything and migrates from nothing. Package-only, and refuses
    /// to run on any database whose name does not end in `_test`.
    package func resetForTests() async throws {
        precondition(name.hasSuffix("_test"), "refusing to wipe \(name): not a *_test database")
        try await client.query("DROP SCHEMA IF EXISTS swift_jobs CASCADE", logger: logger)
        try await client.query("DROP SCHEMA public CASCADE", logger: logger)
        try await client.query("CREATE SCHEMA public", logger: logger)
        try await migrate()
    }

    public func scoped(to user: UserID) -> UserStore {
        UserStore(client: client, logger: logger, user: user)
    }
}
