import BrainCore
import Foundation
import PostgresNIO

// MARK: - Comments

/// What a comment is written against. Exactly one, enforced by M0007.
public enum CommentTarget: Sendable, Hashable {
    case item(ULID)
    case goal(ULID)
    case commitment(ULID)

    var columns: (item: String?, goal: String?, commitment: String?) {
        switch self {
        case .item(let id): (id.rawValue, nil, nil)
        case .goal(let id): (nil, id.rawValue, nil)
        case .commitment(let id): (nil, nil, id.rawValue)
        }
    }
}

public struct StoredComment: Sendable, Equatable {
    public var id: ULID
    public var target: CommentTarget
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: ULID, target: CommentTarget, body: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.target = target
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Count goals

/// A goal's count, when it has one: the target and how many circles are filled.
public struct GoalCount: Sendable, Equatable {
    public var target: Int
    public var done: Int
}

/// One filled circle of a count goal.
public struct GoalMark: Sendable, Equatable {
    public var id: ULID
    public var goalId: ULID
    public var day: CalendarDay
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ULID, goalId: ULID, day: CalendarDay, note: String?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.goalId = goalId
        self.day = day
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum CountRefusal: Error, Equatable {
    /// The goal or thing named is not this user's.
    case unknownTarget
    /// The goal has no target count, so it has no circles to fill.
    case notACountGoal
    /// Every circle is already filled. Raising the target is the user's call.
    case targetReached
    /// A target below the circles already filled, or removed while any are.
    case targetBelowDone(done: Int)
}

extension UserStore {
    // MARK: Comments

    /// Idempotent on id: a retry returns the stored comment and `created == false`.
    public func insertComment(_ comment: StoredComment) async throws
        -> (comment: StoredComment, created: Bool)
    {
        let c = comment.target.columns
        do {
            let created = try await returnsRow(
                """
                INSERT INTO comments (user_id, id, item_id, goal_id, commitment_id, body,
                                      created_at, updated_at)
                VALUES (\(uid), \(comment.id.rawValue), \(c.item), \(c.goal), \(c.commitment),
                        \(comment.body), \(comment.createdAt), \(comment.updatedAt))
                ON CONFLICT (user_id, id) DO NOTHING
                RETURNING id
                """)
            if created { return (comment, true) }
        } catch  where sqlState(of: error) == "23503" {
            throw CountRefusal.unknownTarget
        }
        guard let existing = try await self.comment(comment.id) else {
            throw StorageError.corruptRow(
                table: "comments", column: "id", value: comment.id.rawValue)
        }
        return (existing, false)
    }

    public func comment(_ id: ULID) async throws -> StoredComment? {
        try await comments(
            "SELECT * FROM comments WHERE user_id = \(uid) AND id = \(id.rawValue)"
        ).first
    }

    /// Oldest first, as a conversation reads.
    public func comments(on target: CommentTarget) async throws -> [StoredComment] {
        let c = target.columns
        return try await comments(
            """
            SELECT * FROM comments
            WHERE user_id = \(uid)
              AND item_id IS NOT DISTINCT FROM \(c.item)::text
              AND goal_id IS NOT DISTINCT FROM \(c.goal)::text
              AND commitment_id IS NOT DISTINCT FROM \(c.commitment)::text
            ORDER BY created_at, id
            """)
    }

    /// Returns nil if there is no such comment for this user.
    public func editComment(_ id: ULID, body: String, at date: Date) async throws
        -> StoredComment?
    {
        try await comments(
            """
            UPDATE comments SET body = \(body), updated_at = \(date)
            WHERE user_id = \(uid) AND id = \(id.rawValue)
            RETURNING *
            """
        ).first
    }

    @discardableResult
    public func deleteComment(_ id: ULID) async throws -> Bool {
        try await returnsRow(
            "DELETE FROM comments WHERE user_id = \(uid) AND id = \(id.rawValue) RETURNING id")
    }

    private func comments(_ query: PostgresQuery) async throws -> [StoredComment] {
        var result: [StoredComment] = []
        for try await row in try await client.query(query, logger: logger) {
            let r = RowReader(row: row.makeRandomAccess(), table: "comments")
            func id(_ column: String) throws -> ULID? {
                try r.value(column, as: String?.self).map {
                    try r.parse($0, column: column, ULID.init)
                }
            }
            let target: CommentTarget
            if let item = try id("item_id") {
                target = .item(item)
            } else if let goal = try id("goal_id") {
                target = .goal(goal)
            } else if let commitment = try id("commitment_id") {
                target = .commitment(commitment)
            } else {
                throw StorageError.corruptRow(table: "comments", column: "target", value: "none")
            }
            result.append(
                StoredComment(
                    id: try r.ulid("id"), target: target, body: try r.value("body"),
                    createdAt: try r.value("created_at"), updatedAt: try r.value("updated_at")))
        }
        return result
    }

    // MARK: Count goals

    /// Every count goal of this user's, by goal id. Ordinary goals are absent.
    public func goalCounts() async throws -> [ULID: GoalCount] {
        var result: [ULID: GoalCount] = [:]
        let rows = try await client.query(
            """
            SELECT g.id, g.target_count,
                   (SELECT count(*) FROM goal_marks m
                    WHERE m.user_id = g.user_id AND m.goal_id = g.id) AS done
            FROM goals g
            WHERE g.user_id = \(uid) AND g.target_count IS NOT NULL
            """, logger: logger)
        for try await row in rows {
            let r = RowReader(row: row.makeRandomAccess(), table: "goals")
            result[try r.ulid("id")] = GoalCount(
                target: Int(try r.value("target_count", as: Int32.self)),
                done: Int(try r.value("done", as: Int64.self)))
        }
        return result
    }

    /// Sets or removes a goal's target count, with the goal row locked so a
    /// circle filled meanwhile is counted. Returns false if no such goal.
    @discardableResult
    public func setGoalTarget(_ goal: ULID, to target: Int?) async throws -> Bool {
        do {
            return try await client.withTransaction(logger: logger) { connection in
                guard try await lockGoal(goal, on: connection) else { return false }
                let done = try await markCount(goal, on: connection)
                if done > 0, (target ?? 0) < done {
                    throw CountRefusal.targetBelowDone(done: done)
                }
                try await connection.query(
                    """
                    UPDATE goals SET target_count = \(target)
                    WHERE user_id = \(uid) AND id = \(goal.rawValue)
                    """, logger: logger)
                return true
            }
        } catch let error as PostgresTransactionError {
            // The refusal or database error inside, not the wrapper around it.
            if let inner = error.closureError { throw inner }
            throw error
        }
    }

    public func marks(of goal: ULID) async throws -> [GoalMark] {
        try await marks(
            """
            SELECT id, goal_id, to_char(day, 'YYYY-MM-DD') AS day, note, created_at, updated_at
            FROM goal_marks WHERE user_id = \(uid) AND goal_id = \(goal.rawValue)
            ORDER BY day, created_at, id
            """, on: client)
    }

    /// Fills one circle. Idempotent on id. The goal row is locked, so two
    /// fills at once cannot overshoot the target.
    public func addMark(_ mark: GoalMark) async throws -> (mark: GoalMark, created: Bool) {
        do {
            return try await client.withTransaction(logger: logger) { connection in
                guard try await lockGoal(mark.goalId, on: connection) else {
                    throw CountRefusal.unknownTarget
                }
                if let existing = try await marks(
                    """
                    SELECT id, goal_id, to_char(day, 'YYYY-MM-DD') AS day, note, created_at,
                           updated_at
                    FROM goal_marks WHERE user_id = \(uid) AND id = \(mark.id.rawValue)
                    """, on: connection
                ).first {
                    return (existing, false)
                }
                var target: Int32?
                for try await (value) in try await connection.query(
                    """
                    SELECT target_count FROM goals
                    WHERE user_id = \(uid) AND id = \(mark.goalId.rawValue)
                    """, logger: logger
                ).decode(Int32?.self) {
                    target = value
                }
                guard let target else { throw CountRefusal.notACountGoal }
                guard try await markCount(mark.goalId, on: connection) < Int(target) else {
                    throw CountRefusal.targetReached
                }
                try await connection.query(
                    """
                    INSERT INTO goal_marks (user_id, id, goal_id, day, note, created_at, updated_at)
                    VALUES (\(uid), \(mark.id.rawValue), \(mark.goalId.rawValue),
                            \(mark.day.description)::date, \(mark.note), \(mark.createdAt),
                            \(mark.updatedAt))
                    """, logger: logger)
                return (mark, true)
            }
        } catch let error as PostgresTransactionError {
            // The refusal or database error inside, not the wrapper around it.
            if let inner = error.closureError { throw inner }
            throw error
        }
    }

    /// Changes or removes a circle's note. Returns nil if no such mark on that goal.
    public func editMark(_ id: ULID, goal: ULID, note: String?, at date: Date) async throws
        -> GoalMark?
    {
        try await marks(
            """
            UPDATE goal_marks SET note = \(note), updated_at = \(date)
            WHERE user_id = \(uid) AND id = \(id.rawValue) AND goal_id = \(goal.rawValue)
            RETURNING id, goal_id, to_char(day, 'YYYY-MM-DD') AS day, note, created_at,
                      updated_at
            """, on: client
        ).first
    }

    /// Empties a circle.
    @discardableResult
    public func deleteMark(_ id: ULID, goal: ULID) async throws -> Bool {
        try await returnsRow(
            """
            DELETE FROM goal_marks
            WHERE user_id = \(uid) AND id = \(id.rawValue) AND goal_id = \(goal.rawValue)
            RETURNING id
            """)
    }

    private func lockGoal(_ goal: ULID, on connection: PostgresConnection) async throws -> Bool {
        for try await _ in try await connection.query(
            "SELECT id FROM goals WHERE user_id = \(uid) AND id = \(goal.rawValue) FOR UPDATE",
            logger: logger)
        {
            return true
        }
        return false
    }

    private func markCount(_ goal: ULID, on connection: PostgresConnection) async throws -> Int {
        var count: Int64 = 0
        for try await value in try await connection.query(
            """
            SELECT count(*) FROM goal_marks WHERE user_id = \(uid) AND goal_id = \(goal.rawValue)
            """, logger: logger
        ).decode(Int64.self) {
            count = value
        }
        return Int(count)
    }

    private func marks(_ query: PostgresQuery, on runner: some QueryRunner) async throws
        -> [GoalMark]
    {
        var result: [GoalMark] = []
        for try await row in try await runner.run(query, logger: logger) {
            let r = RowReader(row: row.makeRandomAccess(), table: "goal_marks")
            result.append(
                GoalMark(
                    id: try r.ulid("id"), goalId: try r.ulid("goal_id"), day: try r.day("day"),
                    note: try r.value("note", as: String?.self),
                    createdAt: try r.value("created_at"), updatedAt: try r.value("updated_at")))
        }
        return result
    }
}
