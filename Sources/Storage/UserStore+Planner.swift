import BrainCore
import Foundation
import PostgresNIO

// The planner's storage (`M0005_Planner`, `Brain/docs/15-planner.md`).
// Same rule as the rest of `UserStore`: every query filters on `\(uid)`.

extension CalendarDay {
    /// Parses `YYYY-MM-DD`, the form `description` writes and the database
    /// returns. Fails on anything else, including 30 February.
    public init?(storedValue text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2,
            parts[2].count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }
}

extension GoalPeriod {
    /// Parses `2026-11` (a month) or `2026-Q4` (a quarter): what
    /// `description` writes.
    public init?(storedValue text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, let year = Int(parts[0]) else { return nil }
        if parts[1].count == 2, parts[1].first == "Q", let q = Int(parts[1].dropFirst()) {
            self.init(horizon: .quarter, year: year, index: q)
        } else if parts[1].count == 2, parts[1].allSatisfy(\.isNumber), let m = Int(parts[1]) {
            self.init(horizon: .month, year: year, index: m)
        } else {
            return nil
        }
    }
}

/// A commitment as stored: Brain's template plus what only the server keeps.
public struct StoredCommitment: Sendable, Equatable {
    public var commitment: Commitment
    /// Deleted by the user. Hidden and never scheduled, but its history stays
    /// for the reviews (DECISIONS, 24 Nov).
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(commitment: Commitment, archived: Bool = false, createdAt: Date, updatedAt: Date) {
        self.commitment = commitment
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The state of one occurrence, when it has one (D1). There is deliberately
/// no `missed`: a miss is a day with no row (D2).
public enum OccurrenceState: String, Sendable, Codable, CaseIterable {
    case done, skipped, moved
}

public struct OccurrenceRecord: Sendable, Equatable {
    public var commitmentId: ULID
    /// The day the rule put it on, even when it was moved.
    public var day: CalendarDay
    public var state: OccurrenceState
    /// Where a moved occurrence went. Kept after it is done there.
    public var movedTo: CalendarDay?
    public var updatedAt: Date
}

public struct JournalEntry: Sendable, Equatable {
    public var day: CalendarDay
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
}

public struct DailyPlan: Sendable, Equatable {
    public var day: CalendarDay
    public var itemId: ULID
    public var proposedItemId: ULID?
    public var swapped: Bool
    public var confirmedAt: Date
}

public enum PlannerRefusal: Error, Equatable {
    /// A goal, commitment or item id that is not this user's.
    case unknownReference
}

extension UserStore {
    // MARK: - Commitments

    /// Idempotent on id: a retry returns the stored row and `created == false`.
    public func insertCommitment(_ stored: StoredCommitment) async throws
        -> (commitment: StoredCommitment, created: Bool)
    {
        let c = stored.commitment
        let rule = RuleColumns(c.rule)
        let created: Bool
        do {
            created = try await returnsRow(
                """
                INSERT INTO commitments (
                    user_id, id, title, kind, rule, rule_weekday, rule_day, rule_n, minutes,
                    category, goal_id, start_on, end_on, paused, archived, note,
                    created_at, updated_at)
                VALUES (
                    \(uid), \(c.id.rawValue), \(c.title), \(c.kind.rawValue), \(rule.name),
                    \(rule.weekday), \(rule.day), \(rule.n), \(c.minutes),
                    \(c.category?.rawValue), \(c.goalId?.rawValue), \(c.startOn.description)::date,
                    \(c.endOn?.description)::date, \(c.paused), \(stored.archived), \(c.note),
                    \(stored.createdAt), \(stored.updatedAt))
                ON CONFLICT DO NOTHING
                RETURNING id
                """)
        } catch  where sqlState(of: error) == "23503" {
            throw PlannerRefusal.unknownReference
        }
        if created { return (stored, true) }
        guard let existing = try await commitment(c.id) else {
            throw StorageError.corruptRow(table: "commitments", column: "id", value: c.id.rawValue)
        }
        return (existing, false)
    }

    /// Rewrites every mutable column. Returns false if there is no such
    /// commitment for this user.
    @discardableResult
    public func replaceCommitment(_ stored: StoredCommitment) async throws -> Bool {
        let c = stored.commitment
        let rule = RuleColumns(c.rule)
        do {
            return try await returnsRow(
                """
                UPDATE commitments SET
                    title = \(c.title), kind = \(c.kind.rawValue), rule = \(rule.name),
                    rule_weekday = \(rule.weekday), rule_day = \(rule.day), rule_n = \(rule.n),
                    minutes = \(c.minutes), category = \(c.category?.rawValue),
                    goal_id = \(c.goalId?.rawValue), start_on = \(c.startOn.description)::date,
                    end_on = \(c.endOn?.description)::date, paused = \(c.paused),
                    archived = \(stored.archived), note = \(c.note),
                    updated_at = \(stored.updatedAt)
                WHERE user_id = \(uid) AND id = \(c.id.rawValue)
                RETURNING id
                """)
        } catch  where sqlState(of: error) == "23503" {
            throw PlannerRefusal.unknownReference
        }
    }

    public func commitment(_ id: ULID) async throws -> StoredCommitment? {
        try await commitments(id: id, includeArchived: true).first
    }

    /// Oldest first. Archived ones only when asked for (the reviews want
    /// their history; nothing else does).
    public func commitments(includeArchived: Bool = false) async throws -> [StoredCommitment] {
        try await commitments(id: nil, includeArchived: includeArchived)
    }

    private func commitments(id: ULID?, includeArchived: Bool) async throws
        -> [StoredCommitment]
    {
        let id = id?.rawValue
        let rows = try await client.query(
            """
            SELECT id, title, kind, rule, rule_weekday, rule_day, rule_n, minutes, category,
                   goal_id, to_char(start_on, 'YYYY-MM-DD') AS start_on,
                   to_char(end_on, 'YYYY-MM-DD') AS end_on, paused, archived, note,
                   created_at, updated_at
            FROM commitments
            WHERE user_id = \(uid) AND (\(id)::text IS NULL OR id = \(id)::text)
              AND (\(includeArchived)::boolean OR NOT archived)
            ORDER BY id
            """, logger: logger)
        var result: [StoredCommitment] = []
        for try await row in rows {
            let r = RowReader(row: row.makeRandomAccess(), table: "commitments")
            let rule = try RuleColumns.decode(
                name: try r.value("rule"), weekday: try r.value("rule_weekday", as: Int16?.self),
                day: try r.value("rule_day", as: Int16?.self),
                n: try r.value("rule_n", as: Int16?.self))
            guard let rule else {
                throw StorageError.corruptRow(
                    table: "commitments", column: "rule", value: try r.value("rule"))
            }
            let commitment = Commitment(
                id: try r.ulid("id"), title: try r.value("title"), kind: try r.enumValue("kind"),
                rule: rule, minutes: Int(try r.value("minutes", as: Int32.self)),
                category: try r.value("category", as: String?.self).map {
                    try r.parse($0, column: "category", TaskCategory.init(rawValue:))
                },
                goalId: try r.value("goal_id", as: String?.self).map {
                    try r.parse($0, column: "goal_id", ULID.init)
                },
                startOn: try r.day("start_on"),
                endOn: try r.value("end_on", as: String?.self).map {
                    try r.parse($0, column: "end_on", CalendarDay.init(storedValue:))
                },
                paused: try r.value("paused"), note: try r.value("note", as: String?.self))
            result.append(
                StoredCommitment(
                    commitment: commitment, archived: try r.value("archived"),
                    createdAt: try r.value("created_at"), updatedAt: try r.value("updated_at")))
        }
        return result
    }

    // MARK: - Occurrences

    /// Rows whose day **or** whose moved-to day falls in the closed range, so
    /// a view of a week also sees what was moved into it.
    public func occurrences(from: CalendarDay, through: CalendarDay) async throws
        -> [OccurrenceRecord]
    {
        try await occurrences(
            """
            SELECT commitment_id, to_char(day, 'YYYY-MM-DD') AS day, state,
                   to_char(moved_to, 'YYYY-MM-DD') AS moved_to, updated_at
            FROM occurrences
            WHERE user_id = \(uid)
              AND (day BETWEEN \(from.description)::date AND \(through.description)::date
                   OR moved_to BETWEEN \(from.description)::date AND \(through.description)::date)
            ORDER BY day, commitment_id
            """)
    }

    /// Completed days per commitment, on or after `since`: what Brain's
    /// streaks and `Brain.compute(completed:)` take. A commitment with no
    /// history is simply absent, never an error (D2).
    public func completedDays(since: CalendarDay) async throws -> [ULID: Set<CalendarDay>] {
        let rows = try await occurrences(
            """
            SELECT commitment_id, to_char(day, 'YYYY-MM-DD') AS day, state,
                   to_char(moved_to, 'YYYY-MM-DD') AS moved_to, updated_at
            FROM occurrences
            WHERE user_id = \(uid) AND state = 'done' AND day >= \(since.description)::date
            """)
        return rows.reduce(into: [:]) { $0[$1.commitmentId, default: []].insert($1.day) }
    }

    /// Sets the state of one occurrence, replacing any earlier state. Throws
    /// `unknownReference` if the commitment is not this user's.
    public func setOccurrence(
        _ commitmentId: ULID, day: CalendarDay, state: OccurrenceState, movedTo: CalendarDay?,
        at date: Date
    ) async throws -> OccurrenceRecord {
        do {
            try await client.query(
                """
                INSERT INTO occurrences (user_id, commitment_id, day, state, moved_to, updated_at)
                VALUES (\(uid), \(commitmentId.rawValue), \(day.description)::date,
                        \(state.rawValue), \(movedTo?.description)::date, \(date))
                ON CONFLICT (user_id, commitment_id, day) DO UPDATE
                SET state = excluded.state, moved_to = excluded.moved_to,
                    updated_at = excluded.updated_at
                """, logger: logger)
        } catch  where sqlState(of: error) == "23503" {
            throw PlannerRefusal.unknownReference
        }
        return OccurrenceRecord(
            commitmentId: commitmentId, day: day, state: state, movedTo: movedTo,
            updatedAt: date)
    }

    /// Back to no state. Returns false if there was none.
    @discardableResult
    public func clearOccurrence(_ commitmentId: ULID, day: CalendarDay) async throws -> Bool {
        try await returnsRow(
            """
            DELETE FROM occurrences
            WHERE user_id = \(uid) AND commitment_id = \(commitmentId.rawValue)
              AND day = \(day.description)::date
            RETURNING day
            """)
    }

    private func occurrences(_ query: PostgresQuery) async throws -> [OccurrenceRecord] {
        var result: [OccurrenceRecord] = []
        for try await row in try await client.query(query, logger: logger) {
            let r = RowReader(row: row.makeRandomAccess(), table: "occurrences")
            result.append(
                OccurrenceRecord(
                    commitmentId: try r.ulid("commitment_id"), day: try r.day("day"),
                    state: try r.enumValue("state"),
                    movedTo: try r.value("moved_to", as: String?.self).map {
                        try r.parse($0, column: "moved_to", CalendarDay.init(storedValue:))
                    },
                    updatedAt: try r.value("updated_at")))
        }
        return result
    }

    // MARK: - Journal

    /// One entry per day; writing again replaces the text.
    public func writeJournal(day: CalendarDay, body: String, at date: Date) async throws
        -> JournalEntry
    {
        try await journal(
            """
            INSERT INTO journal_entries (user_id, day, body, created_at, updated_at)
            VALUES (\(uid), \(day.description)::date, \(body), \(date), \(date))
            ON CONFLICT (user_id, day) DO UPDATE
            SET body = excluded.body, updated_at = excluded.updated_at
            RETURNING to_char(day, 'YYYY-MM-DD') AS day, body, created_at, updated_at
            """)[0]
    }

    public func journal(from: CalendarDay, through: CalendarDay) async throws -> [JournalEntry] {
        try await journal(
            """
            SELECT to_char(day, 'YYYY-MM-DD') AS day, body, created_at, updated_at
            FROM journal_entries
            WHERE user_id = \(uid)
              AND day BETWEEN \(from.description)::date AND \(through.description)::date
            ORDER BY day
            """)
    }

    @discardableResult
    public func deleteJournal(day: CalendarDay) async throws -> Bool {
        try await returnsRow(
            """
            DELETE FROM journal_entries WHERE user_id = \(uid) AND day = \(day.description)::date
            RETURNING day
            """)
    }

    private func journal(_ query: PostgresQuery) async throws -> [JournalEntry] {
        var result: [JournalEntry] = []
        for try await row in try await client.query(query, logger: logger) {
            let r = RowReader(row: row.makeRandomAccess(), table: "journal_entries")
            result.append(
                JournalEntry(
                    day: try r.day("day"), body: try r.value("body"),
                    createdAt: try r.value("created_at"), updatedAt: try r.value("updated_at")))
        }
        return result
    }

    // MARK: - Daily plan (D4)

    public func dailyPlans(from: CalendarDay, through: CalendarDay) async throws -> [DailyPlan] {
        try await dailyPlans(from: from, through: through, on: client, lock: false)
    }

    /// The user confirms the day's big task. If it differs from what Brain
    /// proposed, that is a swap, and a `bigTask` correction is recorded
    /// against T0 (the ranking is deterministic rules) — once per change of
    /// choice, not once per call, so a retry records nothing new.
    public func confirmDailyPlan(
        day: CalendarDay, itemId: ULID, proposedItemId: ULID?, at date: Date, correction: ULID
    ) async throws -> DailyPlan {
        let swapped = proposedItemId.map { $0 != itemId } ?? false
        do {
            return try await client.withTransaction(logger: logger) { connection in
                let existing = try await dailyPlans(
                    from: day, through: day, on: connection, lock: true
                ).first
                if let existing, existing.itemId == itemId,
                    existing.proposedItemId == proposedItemId
                {
                    return existing
                }
                try await connection.query(
                    """
                    INSERT INTO daily_plans (user_id, day, item_id, proposed_item_id, swapped,
                                             confirmed_at)
                    VALUES (\(uid), \(day.description)::date, \(itemId.rawValue),
                            \(proposedItemId?.rawValue), \(swapped), \(date))
                    ON CONFLICT (user_id, day) DO UPDATE
                    SET item_id = excluded.item_id, proposed_item_id = excluded.proposed_item_id,
                        swapped = excluded.swapped, confirmed_at = excluded.confirmed_at
                    """, logger: logger)
                if swapped, let proposedItemId, existing?.itemId != itemId {
                    try await insertCorrection(
                        Correction(
                            id: correction, targetId: proposedItemId, field: "bigTask",
                            beforeValue: proposedItemId.rawValue, afterValue: itemId.rawValue,
                            tier: .t0, createdAt: date),
                        on: connection)
                }
                return DailyPlan(
                    day: day, itemId: itemId, proposedItemId: proposedItemId, swapped: swapped,
                    confirmedAt: date)
            }
        } catch  where sqlState(of: error) == "23503" {
            throw PlannerRefusal.unknownReference
        }
    }

    private func dailyPlans(
        from: CalendarDay, through: CalendarDay, on runner: some QueryRunner, lock: Bool
    ) async throws -> [DailyPlan] {
        var query: PostgresQuery = """
            SELECT to_char(day, 'YYYY-MM-DD') AS day, item_id, proposed_item_id, swapped,
                   confirmed_at
            FROM daily_plans
            WHERE user_id = \(uid)
              AND day BETWEEN \(from.description)::date AND \(through.description)::date
            ORDER BY day
            """
        if lock { query.sql += " FOR UPDATE" }
        var result: [DailyPlan] = []
        for try await row in try await runner.run(query, logger: logger) {
            let r = RowReader(row: row.makeRandomAccess(), table: "daily_plans")
            result.append(
                DailyPlan(
                    day: try r.day("day"), itemId: try r.ulid("item_id"),
                    proposedItemId: try r.value("proposed_item_id", as: String?.self).map {
                        try r.parse($0, column: "proposed_item_id", ULID.init)
                    },
                    swapped: try r.value("swapped"), confirmedAt: try r.value("confirmed_at")))
        }
        return result
    }
}

/// A `RecurrenceRule` flattened into the four columns M0005 stores it in.
/// The switch is exhaustive, so a sixth rule in Brain fails to compile here
/// rather than being stored wrongly.
struct RuleColumns {
    let name: String
    let weekday: Int16?
    let day: Int16?
    let n: Int16?

    init(_ rule: RecurrenceRule) {
        switch rule {
        case .daily:
            (name, weekday, day, n) = ("daily", nil, nil, nil)
        case .weeklyOn(let w):
            (name, weekday, day, n) = ("weeklyOn", Int16(w.rawValue), nil, nil)
        case .monthlyOnDay(let d):
            (name, weekday, day, n) = ("monthlyOnDay", nil, Int16(d), nil)
        case .monthlyOnNthWeekday(let k, let w):
            (name, weekday, day, n) = ("monthlyOnNthWeekday", Int16(w.rawValue), nil, Int16(k))
        case .quarterlyOnNthWeekday(let k, let w):
            (name, weekday, day, n) = ("quarterlyOnNthWeekday", Int16(w.rawValue), nil, Int16(k))
        }
    }

    static func decode(name: String, weekday: Int16?, day: Int16?, n: Int16?) throws
        -> RecurrenceRule?
    {
        let w = weekday.flatMap { Weekday(rawValue: Int($0)) }
        switch (name, w, day, n) {
        case ("daily", nil, nil, nil): return .daily
        case ("weeklyOn", let w?, nil, nil): return .weeklyOn(w)
        case ("monthlyOnDay", nil, let d?, nil): return .monthlyOnDay(Int(d))
        case ("monthlyOnNthWeekday", let w?, nil, let k?):
            return .monthlyOnNthWeekday(n: Int(k), weekday: w)
        case ("quarterlyOnNthWeekday", let w?, nil, let k?):
            return .quarterlyOnNthWeekday(n: Int(k), weekday: w)
        default: return nil
        }
    }
}

extension RowReader {
    func day(_ column: String) throws -> CalendarDay {
        try parse(
            try value(column, as: String.self), column: column, CalendarDay.init(storedValue:))
    }
}
