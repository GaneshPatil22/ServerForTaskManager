import BrainHarness
import Logging
import PostgresNIO

/// Brain's `BudgetStore`, kept in Postgres so the free-tier day survives
/// restarts. Mirrors `InMemoryBudgetStore` exactly; `BudgetStoreTests` runs
/// both through the same script and requires identical answers.
///
/// **Atomic check-and-charge.** One transaction that locks the model's row,
/// then the user's row, always in that order, so two callers cannot both pass
/// a check before either writes, and cannot deadlock each other.
///
/// **Fail-closed.** The protocol cannot throw, so if Postgres is unreachable
/// the reservation is *refused*. An uncounted call could overspend the free
/// tier; a refused one only delays enrichment, and the capture is kept.
public struct PostgresBudgetStore: BudgetStore {
    let client: PostgresClient
    let logger: Logger

    public init(database: Database) {
        self.client = database.client
        self.logger = database.logger
    }

    public func reserve(
        model: String, user: String?, day: ProviderDay,
        modelDailyLimit: Int?, userDailyLimit: Int?
    ) async -> BudgetReservation {
        // Fair share applies only when there is both a user and a limit,
        // exactly as in InMemoryBudgetStore.
        let userKey = userDailyLimit == nil ? nil : user
        do {
            return try await client.withTransaction(logger: logger) { connection in
                try await connection.query(
                    """
                    INSERT INTO budget_model_daily (day, model) VALUES (\(day.key), \(model))
                    ON CONFLICT DO NOTHING
                    """, logger: logger)
                let modelUsed = try await Self.lockedCount(
                    connection,
                    """
                    SELECT requests FROM budget_model_daily
                    WHERE day = \(day.key) AND model = \(model) FOR UPDATE
                    """, logger: logger)
                if let limit = modelDailyLimit, modelUsed >= limit {
                    return .refused(.requestsPerDay(limit: limit))
                }

                if let userKey, let limit = userDailyLimit {
                    try await connection.query(
                        """
                        INSERT INTO budget_user_daily (day, user_key) VALUES (\(day.key), \(userKey))
                        ON CONFLICT DO NOTHING
                        """, logger: logger)
                    let userUsed = try await Self.lockedCount(
                        connection,
                        """
                        SELECT requests FROM budget_user_daily
                        WHERE day = \(day.key) AND user_key = \(userKey) FOR UPDATE
                        """, logger: logger)
                    if userUsed >= limit {
                        return .refused(.userFairShare(limit: limit, user: userKey))
                    }
                    try await connection.query(
                        """
                        UPDATE budget_user_daily SET requests = requests + 1
                        WHERE day = \(day.key) AND user_key = \(userKey)
                        """, logger: logger)
                }
                try await connection.query(
                    """
                    UPDATE budget_model_daily SET requests = requests + 1
                    WHERE day = \(day.key) AND model = \(model)
                    """, logger: logger)
                return .reserved
            }
        } catch {
            logger.error(
                "budget store unavailable, refusing the call (fail-closed)",
                metadata: ["error": "\(error)", "model": "\(model)"])
            return .refused(.requestsPerDay(limit: modelDailyLimit ?? 0))
        }
    }

    public func dailyRequests(model: String, day: ProviderDay) async -> Int {
        do {
            let rows = try await client.query(
                """
                SELECT requests FROM budget_model_daily WHERE day = \(day.key) AND model = \(model)
                """, logger: logger)
            for try await (count) in rows.decode(Int.self) { return count }
            return 0
        } catch {
            logger.error("budget store unavailable for reporting", metadata: ["error": "\(error)"])
            return 0
        }
    }

    private static func lockedCount(
        _ connection: PostgresConnection, _ query: PostgresQuery, logger: Logger
    ) async throws -> Int {
        for try await (count) in try await connection.query(query, logger: logger).decode(
            Int.self)
        {
            return count
        }
        return 0
    }
}
