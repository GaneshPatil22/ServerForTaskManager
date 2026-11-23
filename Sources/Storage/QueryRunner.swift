import Logging
import PostgresNIO

/// Something that runs a query: the pool, or one connection inside a
/// transaction. Lets the same insert code run on its own or as part of a
/// larger atomic write.
protocol QueryRunner: Sendable {
    func run(_ query: PostgresQuery, logger: Logger) async throws -> PostgresRowSequence
}

extension PostgresClient: QueryRunner {
    func run(_ query: PostgresQuery, logger: Logger) async throws -> PostgresRowSequence {
        try await self.query(query, logger: logger)
    }
}

extension PostgresConnection: QueryRunner {
    func run(_ query: PostgresQuery, logger: Logger) async throws -> PostgresRowSequence {
        try await self.query(query, logger: logger)
    }
}
