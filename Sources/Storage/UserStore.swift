import BrainCore
import Foundation
import Logging
import PostgresNIO

/// Every read and write for one user. Each query in this file filters on
/// `user_id = self.user`. That filter, together with the composite keys in
/// `M0001_CoreTables`, is the isolation boundary (ADR-0007).
///
/// Reviewing a new method here: if its SQL does not mention `\(uid)`, it is a bug.
public struct UserStore: Sendable {
    let client: PostgresClient
    let logger: Logger
    public let user: UserID

    var uid: UUID { user.rawValue }

    // MARK: - User

    /// Creates the user row on first sight. Safe to call on every request.
    public func ensureUser() async throws {
        try await client.query(
            "INSERT INTO users (id) VALUES (\(uid)) ON CONFLICT (id) DO NOTHING",
            logger: logger)
    }

    /// IANA timezone. "Today" is always computed in it, never the server's.
    public func timezone() async throws -> String? {
        let rows = try await client.query(
            "SELECT timezone FROM users WHERE id = \(uid)", logger: logger)
        for try await (timezone) in rows.decode(String.self) { return timezone }
        return nil
    }

    /// The caller validates the name; the database only stores it.
    public func setTimezone(_ timezone: String) async throws {
        try await client.query(
            "UPDATE users SET timezone = \(timezone) WHERE id = \(uid)", logger: logger)
    }

    // MARK: - Captures

    /// Idempotent. A retry with the same `idempotencyKey`, or the same id,
    /// returns the row already stored and `created == false`. The stored row
    /// wins over the incoming one: captures are never edited.
    public func insertCapture(_ capture: Capture) async throws -> (capture: Capture, created: Bool)
    {
        let rows = try await client.query(
            """
            INSERT INTO captures (user_id, id, raw_text, source, status, idempotency_key, created_at)
            VALUES (\(uid), \(capture.id.rawValue), \(capture.rawText), \(capture.source.rawValue),
                    \(capture.status.rawValue), \(capture.idempotencyKey), \(capture.createdAt))
            ON CONFLICT DO NOTHING
            RETURNING id
            """, logger: logger)
        var created = false
        for try await _ in rows { created = true }
        if created { return (capture, true) }

        if let key = capture.idempotencyKey,
            let existing = try await captures(idempotencyKey: key).first
        {
            return (existing, false)
        }
        if let existing = try await self.capture(capture.id) { return (existing, false) }
        // Unreachable unless a row vanished, which the delete trigger forbids.
        throw StorageError.corruptRow(
            table: "captures", column: "id", value: capture.id.rawValue)
    }

    public func capture(_ id: ULID) async throws -> Capture? {
        try await captures(id: id).first
    }

    /// Oldest first. ULIDs sort by creation time.
    public func captures() async throws -> [Capture] {
        try await captures(id: nil)
    }

    /// One page, oldest first, starting after `after`.
    public func captures(after: ULID?, limit: Int, status: CaptureStatus?) async throws
        -> [Capture]
    {
        try await captures(id: nil, after: after, limit: limit, status: status)
    }

    /// Returns false if no such capture exists for this user.
    @discardableResult
    public func setCaptureStatus(_ id: ULID, _ status: CaptureStatus) async throws -> Bool {
        try await returnsRow(
            """
            UPDATE captures SET status = \(status.rawValue), status_changed_at = now()
            WHERE user_id = \(uid) AND id = \(id.rawValue) RETURNING id
            """)
    }

    /// A nil filter matches everything; the user filter is always applied.
    private func captures(
        id: ULID? = nil, idempotencyKey key: String? = nil, after: ULID? = nil,
        limit: Int? = nil, status: CaptureStatus? = nil
    ) async throws -> [Capture] {
        let id = id?.rawValue
        let after = after?.rawValue
        let status = status?.rawValue
        let query: PostgresQuery = """
            SELECT id, raw_text, source, status, idempotency_key, created_at
            FROM captures
            WHERE user_id = \(uid)
              AND (\(id)::text IS NULL OR id = \(id)::text)
              AND (\(key)::text IS NULL OR idempotency_key = \(key)::text)
              AND (\(after)::text IS NULL OR id > \(after)::text)
              AND (\(status)::text IS NULL OR status = \(status)::text)
            ORDER BY id
            LIMIT \(limit)::bigint
            """
        var result: [Capture] = []
        for try await row in try await client.query(query, logger: logger) {
            let r = RowReader(row: row.makeRandomAccess(), table: "captures")
            result.append(
                Capture(
                    id: try r.ulid("id"), rawText: try r.value("raw_text"),
                    source: try r.enumValue("source"), createdAt: try r.value("created_at"),
                    status: try r.enumValue("status"),
                    idempotencyKey: try r.value("idempotency_key", as: String?.self)))
        }
        return result
    }

    // MARK: - Goals

    /// Idempotent on id: a retry returns the stored goal and `created == false`.
    @discardableResult
    public func insertGoal(_ goal: Goal) async throws -> (goal: Goal, created: Bool) {
        let created = try await returnsRow(
            """
            INSERT INTO goals (user_id, id, title, status, created_at)
            VALUES (\(uid), \(goal.id.rawValue), \(goal.title), \(goal.status.rawValue),
                    \(goal.createdAt))
            ON CONFLICT DO NOTHING
            RETURNING id
            """)
        if created { return (goal, true) }
        guard let existing = try await self.goal(goal.id) else {
            throw StorageError.corruptRow(table: "goals", column: "id", value: goal.id.rawValue)
        }
        return (existing, false)
    }

    public func goal(_ id: ULID) async throws -> Goal? {
        try await goals(id: id).first
    }

    /// Changes only what is passed. Returns nil if no such goal for this user.
    public func updateGoal(_ id: ULID, title: String?, status: GoalStatus?) async throws -> Goal? {
        let status = status?.rawValue
        guard
            try await returnsRow(
                """
                UPDATE goals
                SET title = coalesce(\(title)::text, title),
                    status = coalesce(\(status)::text, status)
                WHERE user_id = \(uid) AND id = \(id.rawValue) RETURNING id
                """)
        else { return nil }
        return try await goal(id)
    }

    public func goals() async throws -> [Goal] {
        try await goals(id: nil)
    }

    private func goals(id: ULID?) async throws -> [Goal] {
        let id = id?.rawValue
        var result: [Goal] = []
        let rows = try await client.query(
            """
            SELECT id, title, status, created_at FROM goals
            WHERE user_id = \(uid) AND (\(id)::text IS NULL OR id = \(id)::text)
            ORDER BY id
            """,
            logger: logger)
        for try await row in rows {
            let r = RowReader(row: row.makeRandomAccess(), table: "goals")
            result.append(
                Goal(
                    id: try r.ulid("id"), title: try r.value("title"),
                    status: try r.enumValue("status"), createdAt: try r.value("created_at")))
        }
        return result
    }

    // MARK: - Items

    public func insertItem(_ item: Item) async throws {
        try await insertItem(item, on: client)
    }

    func insertItem(_ item: Item, on runner: some QueryRunner) async throws {
        let type = ClassifiedBinds(item.type) { $0.rawValue }
        let effort = ClassifiedBinds(item.effort) { $0.rawValue }
        let due = ClassifiedBinds(item.dueAt) { $0 }
        let goal = ClassifiedBinds(item.goalId) { $0.rawValue }
        let category = ClassifiedBinds(item.category) { $0.rawValue }
        _ = try await runner.run(
            """
            INSERT INTO items (
                user_id, id, capture_id, title, status,
                type, type_confidence, type_tier, type_evidence_start, type_evidence_end,
                effort, effort_confidence, effort_tier, effort_evidence_start, effort_evidence_end,
                due_at, due_at_confidence, due_at_tier, due_at_evidence_start, due_at_evidence_end,
                goal_id, goal_id_confidence, goal_id_tier, goal_id_evidence_start,
                goal_id_evidence_end,
                category, category_confidence, category_tier, category_evidence_start,
                category_evidence_end,
                created_at, updated_at)
            VALUES (
                \(uid), \(item.id.rawValue), \(item.captureId?.rawValue), \(item.title),
                \(item.status.rawValue),
                \(type.value), \(type.confidence), \(type.tier), \(type.start), \(type.end),
                \(effort.value), \(effort.confidence), \(effort.tier), \(effort.start),
                \(effort.end),
                \(due.value), \(due.confidence), \(due.tier), \(due.start), \(due.end),
                \(goal.value), \(goal.confidence), \(goal.tier), \(goal.start), \(goal.end),
                \(category.value), \(category.confidence), \(category.tier), \(category.start),
                \(category.end),
                \(item.createdAt), \(item.updatedAt))
            """, logger: logger)
    }

    public func item(_ id: ULID) async throws -> Item? {
        try await items(id: id).first
    }

    public func items() async throws -> [Item] {
        try await items(id: nil)
    }

    /// One page, oldest first, starting after `after`.
    public func items(after: ULID?, limit: Int, status: ItemStatus?) async throws -> [Item] {
        try await items(id: nil, after: after, limit: limit, status: status)
    }

    @discardableResult
    public func setItemStatus(_ id: ULID, _ status: ItemStatus, at date: Date) async throws -> Bool
    {
        try await returnsRow(
            """
            UPDATE items SET status = \(status.rawValue), updated_at = \(date)
            WHERE user_id = \(uid) AND id = \(id.rawValue) RETURNING id
            """)
    }

    private func items(
        id: ULID?, after: ULID? = nil, limit: Int? = nil, status: ItemStatus? = nil
    ) async throws -> [Item] {
        let id = id?.rawValue
        let after = after?.rawValue
        let status = status?.rawValue
        let query: PostgresQuery = """
            SELECT * FROM items
            WHERE user_id = \(uid) AND (\(id)::text IS NULL OR id = \(id)::text)
              AND (\(after)::text IS NULL OR id > \(after)::text)
              AND (\(status)::text IS NULL OR status = \(status)::text)
            ORDER BY id
            LIMIT \(limit)::bigint
            """
        var result: [Item] = []
        for try await row in try await client.query(query, logger: logger) {
            let r = RowReader(row: row.makeRandomAccess(), table: "items")
            result.append(
                Item(
                    id: try r.ulid("id"),
                    captureId: try r.value("capture_id", as: String?.self).map {
                        try r.parse($0, column: "capture_id", ULID.init)
                    },
                    title: try r.value("title"),
                    type: try r.classified("type", as: String.self) { ItemType(rawValue: $0) },
                    status: try r.enumValue("status"),
                    effort: try r.classified("effort", as: String.self) {
                        EffortBucket(rawValue: $0)
                    },
                    dueAt: try r.classified("due_at", as: Date.self) { $0 },
                    goalId: try r.classified("goal_id", as: String.self) { ULID($0) },
                    // Always passed, never nil: nil would make Brain re-derive it
                    // from the title instead of returning what was stored.
                    category: try r.classified("category", as: String.self) {
                        TaskCategory(rawValue: $0)
                    },
                    createdAt: try r.value("created_at"),
                    updatedAt: try r.value("updated_at", as: Date.self)))
        }
        return result
    }

    // MARK: - Edges

    /// The database rejects an edge whose endpoints belong to another user, a
    /// `serves` edge that does not point at a goal, a self-loop, and a
    /// confirmed edge whose source is not the user. **Cycles are not checked
    /// here:** that is Brain's graph code, run before calling this.
    public func insertEdge(_ edge: Edge) async throws {
        _ = try await insertEdge(edge, on: client, skipDuplicate: false)
    }

    /// With `skipDuplicate`, an edge that already exists between the same
    /// pair, of the same kind, is left alone and `false` is returned.
    func insertEdge(_ edge: Edge, on runner: some QueryRunner, skipDuplicate: Bool) async throws
        -> Bool
    {
        let toItem: String? = edge.kind == .serves ? nil : edge.to.rawValue
        let toGoal: String? = edge.kind == .serves ? edge.to.rawValue : nil
        var query: PostgresQuery = """
            INSERT INTO edges (user_id, id, from_item_id, to_item_id, to_goal_id, kind,
                               confidence, source, confirmed)
            VALUES (\(uid), \(edge.id.rawValue), \(edge.from.rawValue), \(toItem), \(toGoal),
                    \(edge.kind.rawValue), \(edge.confidence), \(edge.source.rawValue),
                    \(edge.confirmed))
            """
        query.sql += skipDuplicate ? " ON CONFLICT DO NOTHING RETURNING id" : " RETURNING id"
        for try await _ in try await runner.run(query, logger: logger) { return true }
        return false
    }

    public func edges() async throws -> [Edge] {
        var result: [Edge] = []
        let rows = try await client.query(
            """
            SELECT id, from_item_id, coalesce(to_item_id, to_goal_id) AS to_id, kind,
                   confidence, source, confirmed
            FROM edges WHERE user_id = \(uid) ORDER BY id
            """, logger: logger)
        for try await row in rows {
            let r = RowReader(row: row.makeRandomAccess(), table: "edges")
            result.append(
                Edge(
                    id: try r.ulid("id"), from: try r.ulid("from_item_id"), to: try r.ulid("to_id"),
                    kind: try r.enumValue("kind"), confidence: try r.value("confidence"),
                    source: try r.enumValue("source"), confirmed: try r.value("confirmed")))
        }
        return result
    }

    /// The user confirms an edge, which makes them its source (invariant 3).
    @discardableResult
    public func confirmEdge(_ id: ULID) async throws -> Bool {
        try await returnsRow(
            """
            UPDATE edges SET confirmed = true, source = 'user'
            WHERE user_id = \(uid) AND id = \(id.rawValue) RETURNING id
            """)
    }

    // MARK: - Corrections

    public func insertCorrection(_ correction: Correction) async throws {
        try await client.query(
            """
            INSERT INTO corrections (user_id, id, target_id, field, before_value, after_value,
                                     tier, created_at)
            VALUES (\(uid), \(correction.id.rawValue), \(correction.targetId.rawValue),
                    \(correction.field), \(correction.beforeValue), \(correction.afterValue),
                    \(correction.tier.rawValue), \(correction.createdAt))
            """, logger: logger)
    }

    public func corrections() async throws -> [Correction] {
        var result: [Correction] = []
        let rows = try await client.query(
            """
            SELECT id, target_id, field, before_value, after_value, tier, created_at
            FROM corrections WHERE user_id = \(uid) ORDER BY id
            """, logger: logger)
        for try await row in rows {
            let r = RowReader(row: row.makeRandomAccess(), table: "corrections")
            result.append(
                Correction(
                    id: try r.ulid("id"), targetId: try r.ulid("target_id"),
                    field: try r.value("field"),
                    beforeValue: try r.value("before_value", as: String?.self),
                    afterValue: try r.value("after_value", as: String?.self),
                    tier: try r.enumValue("tier"), createdAt: try r.value("created_at")))
        }
        return result
    }

    // MARK: - Enrichment

    /// Takes a capture for enrichment: moves it to `enriching` and counts the
    /// attempt. Returns nil, and changes nothing, if the capture is already
    /// done, already has an item, or another worker is on it and has not been
    /// stuck for longer than `stuckAfter`. That makes a duplicate job harmless.
    public func claimCapture(_ id: ULID, now: Date, stuckAfter: TimeInterval) async throws
        -> Capture?
    {
        let stuckCutoff = now.addingTimeInterval(-stuckAfter)
        let claimed = try await returnsRow(
            """
            UPDATE captures c
            SET status = 'enriching', status_changed_at = \(now),
                enrich_attempts = enrich_attempts + 1
            WHERE c.user_id = \(uid) AND c.id = \(id.rawValue)
              AND (c.status IN ('raw', 'failed')
                   OR (c.status = 'enriching' AND c.status_changed_at < \(stuckCutoff)))
              AND NOT EXISTS (
                  SELECT 1 FROM items i WHERE i.user_id = c.user_id AND i.capture_id = c.id)
            RETURNING c.id
            """)
        return claimed ? try await capture(id) : nil
    }

    /// Everything Brain needs to rank and link: items, goals and edges.
    /// Edges are added through `BrainGraph.addEdge`, so a stored graph that
    /// somehow held a cycle would fail loudly here rather than be ranked.
    public func graph() async throws -> BrainGraph {
        var graph = BrainGraph()
        for item in try await items() { graph.insert(item) }
        for goal in try await goals() { graph.insert(goal) }
        for edge in try await edges() { _ = try graph.addEdge(edge) }
        return graph
    }

    /// Stores one enrichment atomically: the item, its suggested edges, and
    /// the capture's new status, all or nothing.
    ///
    /// Returns false, and writes nothing, if the capture already has an item.
    /// The capture row is locked first, so two workers finishing the same
    /// capture cannot both write an item. A suggested edge that already exists
    /// is skipped, not an error.
    public func saveEnrichment(
        capture: ULID, status: CaptureStatus, item: Item, edges: [Edge]
    ) async throws -> Bool {
        try await client.withTransaction(logger: logger) { connection in
            var locked = false
            for try await _ in try await connection.query(
                """
                SELECT id FROM captures WHERE user_id = \(uid) AND id = \(capture.rawValue)
                FOR UPDATE
                """, logger: logger)
            {
                locked = true
            }
            guard locked else {
                throw StorageError.corruptRow(
                    table: "captures", column: "id", value: capture.rawValue)
            }
            for try await _ in try await connection.query(
                """
                SELECT 1 FROM items WHERE user_id = \(uid) AND capture_id = \(capture.rawValue)
                """, logger: logger)
            {
                return false
            }
            try await insertItem(item, on: connection)
            for edge in edges {
                _ = try await insertEdge(edge, on: connection, skipDuplicate: true)
            }
            try await connection.query(
                """
                UPDATE captures SET status = \(status.rawValue), status_changed_at = now()
                WHERE user_id = \(uid) AND id = \(capture.rawValue)
                """, logger: logger)
            return true
        }
    }

    // MARK: - Helpers

    private func returnsRow(_ query: PostgresQuery) async throws -> Bool {
        for try await _ in try await client.query(query, logger: logger) { return true }
        return false
    }
}

/// A `Classified<T>` flattened into the five columns `M0001` stores it in.
struct ClassifiedBinds<Raw: PostgresEncodable & Sendable>: Sendable {
    let value: Raw?
    let confidence: Double
    let tier: String
    let start: Int?
    let end: Int?

    init<Value>(_ classified: Classified<Value>, _ raw: (Value) -> Raw) {
        value = classified.value.map(raw)
        confidence = classified.confidence
        tier = classified.tier.rawValue
        start = classified.evidence?.start
        end = classified.evidence?.end
    }
}

/// Decodes columns by name and turns unparseable values into `corruptRow`.
struct RowReader {
    let row: PostgresRandomAccessRow
    let table: String

    func value<T: PostgresDecodable>(_ column: String, as: T.Type = T.self) throws -> T {
        try row[column].decode(T.self)
    }

    func parse<T>(_ raw: String, column: String, _ make: (String) -> T?) throws -> T {
        guard let parsed = make(raw) else {
            throw StorageError.corruptRow(table: table, column: column, value: raw)
        }
        return parsed
    }

    func ulid(_ column: String) throws -> ULID {
        try parse(try value(column, as: String.self), column: column, ULID.init)
    }

    func enumValue<T: RawRepresentable>(_ column: String) throws -> T where T.RawValue == String {
        try parse(try value(column, as: String.self), column: column, T.init(rawValue:))
    }

    func classified<Raw: PostgresDecodable, Value: Sendable & Hashable>(
        _ name: String, as: Raw.Type, _ make: (Raw) -> Value?
    ) throws -> Classified<Value> where Raw._DecodableType == Raw {
        let value: Value? = try self.value(name, as: Raw?.self).map { raw in
            guard let parsed = make(raw) else {
                throw StorageError.corruptRow(table: table, column: name, value: "\(raw)")
            }
            return parsed
        }
        let tier: Tier = try enumValue("\(name)_tier")
        let start = try self.value("\(name)_evidence_start", as: Int?.self)
        let end = try self.value("\(name)_evidence_end", as: Int?.self)
        let evidence = start.flatMap { s in end.map { Span(start: s, end: $0) } }
        return Classified(
            value, confidence: try self.value("\(name)_confidence"), tier: tier,
            evidence: evidence)
    }
}
