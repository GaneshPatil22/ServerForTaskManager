import BrainCore
import Foundation
import Logging
import PostgresNIO
import Testing

@testable import Storage
@_exported import TestDatabase

/// Whole seconds, so a value survives the round trip through `timestamptz`
/// (microsecond precision) and compares equal.
let fixedDate = Date(timeIntervalSince1970: 1_795_000_000)

/// Runs `body` and requires it to fail with this Postgres SQLSTATE.
/// 23503 foreign key, 23514 check, 23505 unique, P0001 raised by a trigger.
func expectSQLState(
    _ state: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("expected SQLSTATE \(state), but it succeeded", sourceLocation: sourceLocation)
    } catch let error as PSQLError {
        #expect(error.serverInfo?[.sqlState] == state, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected PSQLError, got \(error)", sourceLocation: sourceLocation)
    }
}

/// A user's full set of rows: one of everything, linked together.
struct Seed {
    let capture: Capture
    let goal: Goal
    let item: Item
    let other: Item
    let edge: Edge
    let correction: Correction

    static func insert(into store: UserStore) async throws -> Seed {
        let capture = Capture(id: newID(), rawText: "call bank re 50K loan", createdAt: fixedDate)
        let goal = Goal(id: newID(), title: "sort out finances", createdAt: fixedDate)
        let item = Item(
            id: newID(), captureId: capture.id, title: "call bank",
            type: Classified(.task, confidence: 0.9, tier: .t0, evidence: Span(start: 0, end: 4)),
            effort: Classified(.small, confidence: 0.6, tier: .t2),
            dueAt: Classified(
                fixedDate, confidence: 1, tier: .t0, evidence: Span(start: 5, end: 9)),
            goalId: Classified(goal.id, confidence: 1, tier: .user),
            category: Classified(.communication, confidence: 0.8, tier: .t0),
            createdAt: fixedDate)
        let other = Item(
            id: newID(), captureId: capture.id, title: "get loan", createdAt: fixedDate)
        let edge = Edge(id: newID(), from: item.id, to: other.id, kind: .blocks, source: .t0Rule)
        let correction = Correction(
            id: newID(), targetId: item.id, field: "effort", beforeValue: "small",
            afterValue: "medium", tier: .t2, createdAt: fixedDate)

        _ = try await store.insertCapture(capture)
        try await store.insertGoal(goal)
        try await store.insertItem(item)
        try await store.insertItem(other)
        try await store.insertEdge(edge)
        try await store.insertCorrection(correction)
        return Seed(
            capture: capture, goal: goal, item: item, other: other, edge: edge,
            correction: correction)
    }
}
