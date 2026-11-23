import Logging
import PostgresMigrations
import PostgresNIO

/// Daily model-call counters, so a restart or deploy cannot reset the
/// free-tier day and quietly overspend it (Brain 0.5.0, `BudgetStore`).
///
/// **Not user data.** These are deployment-wide counters. `user_key` is the
/// user's id as a string, used only to enforce their fair share; nothing is
/// ever read back to a user from here. That is why `PostgresBudgetStore`
/// is not part of `UserStore`.
///
/// `day` is `ProviderDay.key`: the calendar day in America/Los_Angeles,
/// when Google's RPD resets (verified by the Brain session, 2026-11-24).
struct M0002_BudgetCounters: DatabaseMigration {
    static let statements = [
        """
        CREATE TABLE budget_model_daily (
            day text NOT NULL,
            model text NOT NULL,
            requests integer NOT NULL DEFAULT 0 CHECK (requests >= 0),
            PRIMARY KEY (day, model)
        )
        """,
        """
        CREATE TABLE budget_user_daily (
            day text NOT NULL,
            user_key text NOT NULL,
            requests integer NOT NULL DEFAULT 0 CHECK (requests >= 0),
            PRIMARY KEY (day, user_key)
        )
        """,
        "ALTER TABLE budget_model_daily ENABLE ROW LEVEL SECURITY",
        "ALTER TABLE budget_user_daily ENABLE ROW LEVEL SECURITY",
    ]

    func apply(connection: PostgresConnection, logger: Logger) async throws {
        for statement in Self.statements {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        for table in ["budget_user_daily", "budget_model_daily"] {
            try await connection.query(
                PostgresQuery(unsafeSQL: "DROP TABLE IF EXISTS \(table)"), logger: logger)
        }
    }
}
