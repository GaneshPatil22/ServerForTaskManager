import Logging
import PostgresMigrations
import PostgresNIO

/// The planner (`Brain/docs/15-planner.md`): commitments, their occurrences,
/// the journal, period goals and the daily big task.
///
/// The decisions the shape follows from:
///
/// - **Commitments are not items** and have their own table. They are
///   scheduled, never ranked.
/// - **D1: the rule is stored, occurrences are not generated.** The days come
///   from Brain's `Commitment.days(from:through:)` on read. `occurrences`
///   holds a row only for a day that carries state.
/// - **D2: no row for a missed day**, and no `missed` state: missed is
///   expected minus actual.
/// - **The journal is not an item** either: it does not rank, block or finish.
/// - **D4:** `daily_plans` records the big task the user confirmed and whether
///   it was a swap; the swap itself is also a `bigTask` correction.
///
/// The rule is a discriminator plus three small columns rather than JSON, so
/// the database can check each shape (a weekly rule has a weekday and nothing
/// else, and so on). Like M0001, every value list is literal and frozen;
/// `SchemaDriftTests` catches Brain growing a case.
///
/// `note` is free text such as "22k". It is never parsed and never summed:
/// arithmetic over amounts is the expense tracking the charter rejects.
struct M0005_Planner: DatabaseMigration {
    static let commitmentKinds = ["habit", "ritual", "payment", "block"]
    static let rules = [
        "daily", "weeklyOn", "monthlyOnDay", "monthlyOnNthWeekday", "quarterlyOnNthWeekday",
    ]
    static let occurrenceStates = ["done", "skipped", "moved"]
    static let tables = ["daily_plans", "journal_entries", "occurrences", "commitments"]

    static var statements: [String] {
        let list = M0001_CoreTables.list
        return [
            """
            CREATE TABLE commitments (
                user_id uuid NOT NULL REFERENCES users (id),
                id ulid NOT NULL,
                title text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
                kind text NOT NULL CHECK (kind IN \(list(commitmentKinds))),
                rule text NOT NULL CHECK (rule IN \(list(rules))),
                rule_weekday smallint CHECK (rule_weekday BETWEEN 1 AND 7),
                rule_day smallint CHECK (rule_day BETWEEN 1 AND 31),
                rule_n smallint CHECK (rule_n BETWEEN 1 AND 5),
                minutes integer NOT NULL CHECK (minutes BETWEEN 0 AND 1440),
                category text CHECK (category IN \(list(M0001_CoreTables.taskCategories))),
                goal_id ulid,
                start_on date NOT NULL,
                end_on date CHECK (end_on >= start_on),
                paused boolean NOT NULL DEFAULT false,
                archived boolean NOT NULL DEFAULT false,
                note text CHECK (length(note) <= 200),
                created_at timestamptz NOT NULL,
                updated_at timestamptz NOT NULL,
                PRIMARY KEY (user_id, id),
                FOREIGN KEY (user_id, goal_id) REFERENCES goals (user_id, id),
                CHECK (
                    (rule = 'daily'
                        AND rule_weekday IS NULL AND rule_day IS NULL AND rule_n IS NULL)
                    OR (rule = 'weeklyOn'
                        AND rule_weekday IS NOT NULL AND rule_day IS NULL AND rule_n IS NULL)
                    OR (rule = 'monthlyOnDay'
                        AND rule_weekday IS NULL AND rule_day IS NOT NULL AND rule_n IS NULL)
                    OR (rule IN ('monthlyOnNthWeekday', 'quarterlyOnNthWeekday')
                        AND rule_weekday IS NOT NULL AND rule_day IS NULL AND rule_n IS NOT NULL))
            )
            """,

            // `moved_to` survives a move that was later completed, so the
            // history says where it was done. A skip is never moved.
            """
            CREATE TABLE occurrences (
                user_id uuid NOT NULL,
                commitment_id ulid NOT NULL,
                day date NOT NULL,
                state text NOT NULL CHECK (state IN \(list(occurrenceStates))),
                moved_to date CHECK (moved_to <> day),
                updated_at timestamptz NOT NULL,
                PRIMARY KEY (user_id, commitment_id, day),
                FOREIGN KEY (user_id, commitment_id) REFERENCES commitments (user_id, id),
                CHECK (state <> 'moved' OR moved_to IS NOT NULL),
                CHECK (state <> 'skipped' OR moved_to IS NULL)
            )
            """,
            "CREATE INDEX occurrences_by_day ON occurrences (user_id, day)",
            "CREATE INDEX occurrences_by_moved_to ON occurrences (user_id, moved_to)",

            """
            CREATE TABLE journal_entries (
                user_id uuid NOT NULL REFERENCES users (id),
                day date NOT NULL,
                body text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
                created_at timestamptz NOT NULL,
                updated_at timestamptz NOT NULL,
                PRIMARY KEY (user_id, day)
            )
            """,

            // Whether a month goal may name a quarter parent (`canRollUp`) is
            // checked by the server before writing; the database guarantees
            // only the format and that the parent is the same user's goal.
            """
            ALTER TABLE goals
                ADD COLUMN period text
                    CHECK (period ~ '^[0-9]{4}-(0[1-9]|1[0-2]|Q[1-4])$'),
                ADD COLUMN parent_id ulid CHECK (parent_id <> id),
                ADD FOREIGN KEY (user_id, parent_id) REFERENCES goals (user_id, id)
            """,
            "CREATE INDEX goals_by_period ON goals (user_id, period)",

            """
            CREATE TABLE daily_plans (
                user_id uuid NOT NULL REFERENCES users (id),
                day date NOT NULL,
                item_id ulid NOT NULL,
                proposed_item_id ulid,
                swapped boolean NOT NULL,
                confirmed_at timestamptz NOT NULL,
                PRIMARY KEY (user_id, day),
                FOREIGN KEY (user_id, item_id) REFERENCES items (user_id, id),
                FOREIGN KEY (user_id, proposed_item_id) REFERENCES items (user_id, id),
                CHECK (swapped = coalesce(proposed_item_id <> item_id, false))
            )
            """,
            // postgres-migrations' own bookkeeping table lives in `public`
            // and was created with RLS off. Nothing reads it but the server,
            // which owns it and so bypasses RLS; this only shuts the data API out.
            "ALTER TABLE _hb_pg_migrations ENABLE ROW LEVEL SECURITY",
        ] + tables.map { "ALTER TABLE \($0) ENABLE ROW LEVEL SECURITY" }
    }

    func apply(connection: PostgresConnection, logger: Logger) async throws {
        for statement in Self.statements {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        var statements = Self.tables.map { "DROP TABLE IF EXISTS \($0)" }
        statements += [
            "DROP INDEX IF EXISTS goals_by_period",
            "ALTER TABLE goals DROP COLUMN parent_id, DROP COLUMN period",
        ]
        for statement in statements {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }
}
