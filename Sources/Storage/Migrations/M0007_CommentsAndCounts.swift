import Logging
import PostgresMigrations
import PostgresNIO

/// Comments and count goals (`Brain/docs/00-charter.md`, "Outside Brain, not
/// outside the product"). The user's own records: Brain never reads them,
/// never classifies them, and they are never sent to a model.
///
/// - **A comment points at exactly one thing**, through a real foreign key per
///   kind (item, goal, commitment) and a CHECK that exactly one is set. A
///   comment can never point at nothing.
/// - **A count goal is opt-in**: `goals.target_count` is null for an ordinary
///   goal. Each filled circle is a `goal_marks` row with its day and an
///   optional note.
/// - **Counts of things, never money.** A target is a whole number of things
///   (1–1000) and a mark is one occurrence. There is no amount, unit or sum
///   anywhere: expense tracking is a rejected non-goal.
///
/// Additive only: two new tables and one nullable column. The previous image
/// names its goal columns, so it ignores `target_count`.
struct M0007_CommentsAndCounts: DatabaseMigration {
    static let tables = ["comments", "goal_marks"]

    static var statements: [String] {
        [
            """
            CREATE TABLE comments (
                user_id uuid NOT NULL REFERENCES users (id),
                id ulid NOT NULL,
                item_id ulid,
                goal_id ulid,
                commitment_id ulid,
                body text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
                created_at timestamptz NOT NULL,
                updated_at timestamptz NOT NULL,
                PRIMARY KEY (user_id, id),
                FOREIGN KEY (user_id, item_id) REFERENCES items (user_id, id),
                FOREIGN KEY (user_id, goal_id) REFERENCES goals (user_id, id),
                FOREIGN KEY (user_id, commitment_id) REFERENCES commitments (user_id, id),
                CHECK (num_nonnulls(item_id, goal_id, commitment_id) = 1)
            )
            """,
            """
            CREATE INDEX comments_by_item ON comments (user_id, item_id, created_at)
            WHERE item_id IS NOT NULL
            """,
            """
            CREATE INDEX comments_by_goal ON comments (user_id, goal_id, created_at)
            WHERE goal_id IS NOT NULL
            """,
            """
            CREATE INDEX comments_by_commitment ON comments (user_id, commitment_id, created_at)
            WHERE commitment_id IS NOT NULL
            """,

            """
            ALTER TABLE goals
                ADD COLUMN target_count integer CHECK (target_count BETWEEN 1 AND 1000)
            """,
            """
            CREATE TABLE goal_marks (
                user_id uuid NOT NULL,
                id ulid NOT NULL,
                goal_id ulid NOT NULL,
                day date NOT NULL,
                note text CHECK (length(note) BETWEEN 1 AND 500),
                created_at timestamptz NOT NULL,
                updated_at timestamptz NOT NULL,
                PRIMARY KEY (user_id, id),
                FOREIGN KEY (user_id, goal_id) REFERENCES goals (user_id, id)
            )
            """,
            "CREATE INDEX goal_marks_by_goal ON goal_marks (user_id, goal_id, day)",
        ] + tables.map { "ALTER TABLE \($0) ENABLE ROW LEVEL SECURITY" }
    }

    func apply(connection: PostgresConnection, logger: Logger) async throws {
        for statement in Self.statements {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        for statement in [
            "DROP TABLE IF EXISTS goal_marks", "DROP TABLE IF EXISTS comments",
            "ALTER TABLE goals DROP COLUMN IF EXISTS target_count",
        ] {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }
}
