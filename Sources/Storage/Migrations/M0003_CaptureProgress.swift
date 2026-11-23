import Logging
import PostgresMigrations
import PostgresNIO

/// What the enrichment worker and its sweeper need to know about a capture:
/// when its status last changed (to spot a worker that died mid-capture) and
/// how many times it has been tried (so a capture that always fails stops
/// being retried forever, but is still kept).
///
/// The capture guard trigger compares only the immutable columns, so these
/// two may change like `status` does.
struct M0003_CaptureProgress: DatabaseMigration {
    static let statements = [
        "ALTER TABLE captures ADD COLUMN status_changed_at timestamptz NOT NULL DEFAULT now()",
        "ALTER TABLE captures ADD COLUMN enrich_attempts integer NOT NULL DEFAULT 0",
        """
        CREATE INDEX captures_needing_work ON captures (status_changed_at)
            WHERE status IN ('raw', 'enriching', 'failed')
        """,
        "CREATE INDEX items_by_capture ON items (user_id, capture_id)",
    ]

    func apply(connection: PostgresConnection, logger: Logger) async throws {
        for statement in Self.statements {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        for statement in [
            "DROP INDEX IF EXISTS items_by_capture",
            "DROP INDEX IF EXISTS captures_needing_work",
            "ALTER TABLE captures DROP COLUMN enrich_attempts",
            "ALTER TABLE captures DROP COLUMN status_changed_at",
        ] {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }
}
