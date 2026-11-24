import Logging
import PostgresMigrations
import PostgresNIO

/// T3: the questions Brain asks when every tier abstains (S6b).
///
/// - **Never outlives its item.** `item_id` is NOT NULL and a foreign key:
///   every enrichment result has an item, a failed capture included, and the
///   question is written in the same transaction as that item.
/// - **The closed set holds in the database too.** `answer` must be one of
///   the stored `options`, so neither a model nor a client can store anything
///   else. That is the hallucination defence, applied to human input.
/// - **One question per field per item.** A retried enrichment cannot ask twice.
/// - **Only fields the server can apply.** Today that is `type`; a field
///   Brain starts asking about is refused here until the server learns to
///   apply its answer.
///
/// Additive only: a new table, nothing existing changes. Rolling the image
/// back leaves it unread.
struct M0006_Questions: DatabaseMigration {
    static let fields = ["type"]

    static var statements: [String] {
        let list = M0001_CoreTables.list
        return [
            """
            CREATE TABLE questions (
                user_id uuid NOT NULL REFERENCES users (id),
                id ulid NOT NULL,
                capture_id ulid NOT NULL,
                item_id ulid NOT NULL,
                field text NOT NULL CHECK (field IN \(list(fields))),
                prompt text NOT NULL CHECK (length(prompt) BETWEEN 1 AND 500),
                options text[] NOT NULL CHECK (cardinality(options) BETWEEN 2 AND 20),
                created_at timestamptz NOT NULL,
                answered_at timestamptz,
                answer text,
                PRIMARY KEY (user_id, id),
                UNIQUE (user_id, item_id, field),
                FOREIGN KEY (user_id, capture_id) REFERENCES captures (user_id, id),
                FOREIGN KEY (user_id, item_id) REFERENCES items (user_id, id),
                CHECK ((answered_at IS NULL) = (answer IS NULL)),
                CHECK (answer IS NULL OR answer = ANY (options))
            )
            """,
            """
            CREATE INDEX questions_unanswered ON questions (user_id, created_at DESC)
            WHERE answered_at IS NULL
            """,
            "ALTER TABLE questions ENABLE ROW LEVEL SECURITY",
        ]
    }

    func apply(connection: PostgresConnection, logger: Logger) async throws {
        for statement in Self.statements {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query("DROP TABLE IF EXISTS questions", logger: logger)
    }
}
