import BrainCore
import Foundation
import Logging
import PostgresMigrations
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
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var database: String

    public init(host: String, port: Int, username: String, password: String, database: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
    }

    /// Reads `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`,
    /// `DATABASE_PASSWORD`, `DATABASE_NAME`. No defaults: a missing value is
    /// an error, so production never silently connects somewhere local.
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
        return .init(
            host: try require("DATABASE_HOST"), port: port,
            username: try require("DATABASE_USER"), password: try require("DATABASE_PASSWORD"),
            database: try require("DATABASE_NAME"))
    }

    /// TLS is off: this is for the local Docker database. Connecting to
    /// Supabase needs TLS, which is added with deployment (S6).
    var clientConfiguration: PostgresClient.Configuration {
        .init(
            host: host, port: port, username: username, password: password,
            database: database, tls: .disable)
    }
}

/// The only way into the data. The Postgres client is internal to this
/// module, so code outside it cannot write a query at all: it has to ask for
/// `scoped(to:)` and gets a store that already carries the user's id.
public final class Database: Sendable {
    let client: PostgresClient
    let logger: Logger
    let name: String

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

    /// Applies every migration not yet applied, in one transaction.
    public func migrate() async throws {
        let migrations = DatabaseMigrations()
        await migrations.add(M0001_CoreTables())
        await migrations.add(M0002_BudgetCounters())
        try await migrations.apply(client: client, logger: logger, dryRun: false)
    }

    /// Drops everything and migrates from nothing. Package-only, and refuses
    /// to run on any database whose name does not end in `_test`.
    package func resetForTests() async throws {
        precondition(name.hasSuffix("_test"), "refusing to wipe \(name): not a *_test database")
        try await client.query("DROP SCHEMA public CASCADE", logger: logger)
        try await client.query("CREATE SCHEMA public", logger: logger)
        try await migrate()
    }

    public func scoped(to user: UserID) -> UserStore {
        UserStore(client: client, logger: logger, user: user)
    }
}
