import Logging
import PostgresMigrations
import PostgresNIO

/// A rejected link stays as a row, marked `rejected`, instead of being
/// deleted. The unique (user, from, to, kind) index already covers it, so the
/// worker's `ON CONFLICT DO NOTHING` can never suggest that link again, with
/// no extra lookup. Rejected rows are left out of every read and the graph.
struct M0004_RejectedLinks: DatabaseMigration {
    static let statements = [
        "ALTER TABLE edges ADD COLUMN rejected boolean NOT NULL DEFAULT false",
        "ALTER TABLE edges ADD CONSTRAINT edges_rejected_not_confirmed CHECK (NOT (rejected AND confirmed))",
    ]

    func apply(connection: PostgresConnection, logger: Logger) async throws {
        for statement in Self.statements {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        for statement in [
            "ALTER TABLE edges DROP CONSTRAINT edges_rejected_not_confirmed",
            "ALTER TABLE edges DROP COLUMN rejected",
        ] {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }
}
