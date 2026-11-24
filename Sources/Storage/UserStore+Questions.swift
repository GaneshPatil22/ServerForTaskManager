import BrainCore
import Foundation
import PostgresNIO

/// A T3 question as stored (M0006).
public struct StoredQuestion: Sendable, Equatable {
    public var id: ULID
    public var captureId: ULID
    public var itemId: ULID
    public var field: String
    public var prompt: String
    public var options: [String]
    public var createdAt: Date
    public var answeredAt: Date?
    public var answer: String?

    /// The fields whose answer the server knows how to apply to an item.
    /// Matches M0006's CHECK; a question about any other field is not stored.
    public static let answerableFields: Set<String> = Set(M0006_Questions.fields)

    public init(
        id: ULID, captureId: ULID, itemId: ULID, field: String, prompt: String,
        options: [String], createdAt: Date, answeredAt: Date? = nil, answer: String? = nil
    ) {
        self.id = id
        self.captureId = captureId
        self.itemId = itemId
        self.field = field
        self.prompt = prompt
        self.options = options
        self.createdAt = createdAt
        self.answeredAt = answeredAt
        self.answer = answer
    }
}

public enum QuestionRefusal: Error, Equatable {
    /// The answer is not one of the stored options.
    case notAnOption
    /// Already answered with a different option. Changing one's mind is an
    /// item edit, which records its own correction.
    case alreadyAnswered
}

extension UserStore {
    /// Unanswered questions, newest first.
    public func openQuestions(limit: Int = 50) async throws -> [StoredQuestion] {
        try await questions(
            """
            SELECT * FROM questions
            WHERE user_id = \(uid) AND answered_at IS NULL
            ORDER BY created_at DESC, id DESC
            LIMIT \(limit)
            """, on: client)
    }

    public func question(_ id: ULID) async throws -> StoredQuestion? {
        try await questions(
            "SELECT * FROM questions WHERE user_id = \(uid) AND id = \(id.rawValue)", on: client
        ).first
    }

    /// Answers a question: records the answer, sets the item's field as the
    /// user's decision, and writes a `t3` correction — the label for exactly
    /// the case no tier could read. One transaction, question and item locked.
    ///
    /// Returns nil if there is no such question for this user. Answering
    /// again with the same option returns the stored question and writes
    /// nothing, so a retry cannot double-count a label.
    public func answerQuestion(
        _ id: ULID, option: String, at date: Date, correction: ULID
    ) async throws -> StoredQuestion? {
        do {
            return try await answer(id, option: option, at: date, correction: correction)
        } catch let error as PostgresTransactionError {
            // The refusal, not the transaction wrapping it, is the caller's answer.
            if let refusal = error.closureError as? QuestionRefusal { throw refusal }
            throw error
        }
    }

    private func answer(
        _ id: ULID, option: String, at date: Date, correction: ULID
    ) async throws -> StoredQuestion? {
        try await client.withTransaction(logger: logger) { connection in
            guard
                var question = try await questions(
                    """
                    SELECT * FROM questions WHERE user_id = \(uid) AND id = \(id.rawValue)
                    FOR UPDATE
                    """, on: connection
                ).first
            else { return nil }
            // Checked against what was stored, never against what the client
            // says the options were.
            guard question.options.contains(option) else { throw QuestionRefusal.notAnOption }
            if let answer = question.answer {
                guard answer == option else { throw QuestionRefusal.alreadyAnswered }
                return question
            }

            guard
                var item = try await items(
                    id: question.itemId, after: nil, limit: nil, status: nil, on: connection,
                    lock: true
                ).first
            else {
                throw StorageError.corruptRow(
                    table: "questions", column: "item_id", value: question.itemId.rawValue)
            }
            let before: String?
            switch question.field {
            case "type":
                guard let type = ItemType(rawValue: option) else {
                    throw StorageError.corruptRow(
                        table: "questions", column: "options", value: option)
                }
                before = item.type.value?.rawValue
                item.type = Classified(type, confidence: 1, tier: .user)
            default:
                throw StorageError.corruptRow(
                    table: "questions", column: "field", value: question.field)
            }
            item.updatedAt = date
            try await replaceItem(item, on: connection)
            try await insertCorrection(
                Correction(
                    id: correction, targetId: item.id, field: question.field,
                    beforeValue: before, afterValue: option, tier: .t3, createdAt: date),
                on: connection)
            try await connection.query(
                """
                UPDATE questions SET answered_at = \(date), answer = \(option)
                WHERE user_id = \(uid) AND id = \(id.rawValue)
                """, logger: logger)
            question.answeredAt = date
            question.answer = option
            return question
        }
    }

    func insertQuestion(_ question: StoredQuestion, on runner: some QueryRunner) async throws {
        _ = try await runner.run(
            """
            INSERT INTO questions (user_id, id, capture_id, item_id, field, prompt, options,
                                   created_at)
            VALUES (\(uid), \(question.id.rawValue), \(question.captureId.rawValue),
                    \(question.itemId.rawValue), \(question.field), \(question.prompt),
                    \(question.options), \(question.createdAt))
            ON CONFLICT (user_id, item_id, field) DO NOTHING
            """, logger: logger)
    }

    /// Marks an open question answered without a correction of its own:
    /// the caller has already recorded one.
    func closeQuestion(
        item: ULID, field: String, answer: String, at date: Date, on runner: some QueryRunner
    ) async throws {
        _ = try await runner.run(
            """
            UPDATE questions SET answered_at = \(date), answer = \(answer)
            WHERE user_id = \(uid) AND item_id = \(item.rawValue) AND field = \(field)
              AND answered_at IS NULL AND \(answer) = ANY (options)
            """, logger: logger)
    }

    private func questions(_ query: PostgresQuery, on runner: some QueryRunner) async throws
        -> [StoredQuestion]
    {
        var result: [StoredQuestion] = []
        for try await row in try await runner.run(query, logger: logger) {
            let r = RowReader(row: row.makeRandomAccess(), table: "questions")
            result.append(
                StoredQuestion(
                    id: try r.ulid("id"), captureId: try r.ulid("capture_id"),
                    itemId: try r.ulid("item_id"), field: try r.value("field"),
                    prompt: try r.value("prompt"), options: try r.value("options"),
                    createdAt: try r.value("created_at"),
                    answeredAt: try r.value("answered_at", as: Date?.self),
                    answer: try r.value("answer", as: String?.self)))
        }
        return result
    }
}
