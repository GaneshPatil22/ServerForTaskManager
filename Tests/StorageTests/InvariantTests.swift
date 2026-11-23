import BrainCore
import Foundation
import Testing

@testable import Storage

/// Domain rules the database enforces on its own, even against raw SQL that
/// bypasses `UserStore`.
@Suite("Database invariants")
struct InvariantTests {
    @Test func everythingRoundTripsUnchanged() async throws {
        let store = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: store)

        #expect(try await store.captures() == [seed.capture])
        #expect(try await store.goals() == [seed.goal])
        #expect(try await store.item(seed.item.id) == seed.item)
        #expect(try await store.item(seed.other.id) == seed.other)
        #expect(try await store.edges() == [seed.edge])
        #expect(try await store.corrections() == [seed.correction])
    }

    @Test func storedCategoryIsNotReDerived() async throws {
        let store = try await TestDatabase.newUser()
        // A user said "planning" for a title the T0 lexicon would read differently.
        let item = Item(
            id: newID(), title: "call mom",
            category: Classified(.planning, confidence: 1, tier: .user), createdAt: fixedDate)
        try await store.insertItem(item)
        #expect(try await store.item(item.id)?.category.value == .planning)
    }

    @Test func captureRetryIsIdempotent() async throws {
        let store = try await TestDatabase.newUser()
        let first = Capture(
            id: newID(), rawText: "original", createdAt: fixedDate, idempotencyKey: "retry-1")
        // Same key, different id and text: a client retry after a dropped response.
        let retry = Capture(
            id: newID(), rawText: "changed", createdAt: fixedDate, idempotencyKey: "retry-1")

        #expect(try await store.insertCapture(first).created)
        let second = try await store.insertCapture(retry)
        #expect(second.created == false)
        #expect(second.capture == first)
        #expect(try await store.captures().count == 1)
    }

    @Test func capturesAreNeverDeletedOrEdited() async throws {
        let store = try await TestDatabase.newUser()
        let db = try await TestDatabase.get()
        let capture = Capture(id: newID(), rawText: "keep me", createdAt: fixedDate)
        _ = try await store.insertCapture(capture)
        let uid = store.user.rawValue

        await expectSQLState("P0001") {
            try await db.client.query("DELETE FROM captures WHERE user_id = \(uid)")
        }
        await expectSQLState("P0001") {
            try await db.client.query(
                "UPDATE captures SET raw_text = 'rewritten' WHERE user_id = \(uid)")
        }
        // Status is the one field that may change.
        #expect(try await store.setCaptureStatus(capture.id, .enriched))
        #expect(try await store.capture(capture.id)?.rawText == "keep me")
    }

    @Test func correctionsAreAppendOnly() async throws {
        let store = try await TestDatabase.newUser()
        let db = try await TestDatabase.get()
        _ = try await Seed.insert(into: store)
        let uid = store.user.rawValue

        await expectSQLState("P0001") {
            try await db.client.query("DELETE FROM corrections WHERE user_id = \(uid)")
        }
        await expectSQLState("P0001") {
            try await db.client.query(
                "UPDATE corrections SET after_value = 'x' WHERE user_id = \(uid)")
        }
    }

    /// Brain's `Edge` init already refuses this, so go around it with raw SQL.
    @Test func onlyTheUserCanConfirmAnEdge() async throws {
        let store = try await TestDatabase.newUser()
        let db = try await TestDatabase.get()
        let seed = try await Seed.insert(into: store)
        let uid = store.user.rawValue
        let id = newID().rawValue
        let from = seed.other.id.rawValue
        let to = seed.item.id.rawValue

        await expectSQLState("23514") {
            try await db.client.query(
                """
                INSERT INTO edges (user_id, id, from_item_id, to_item_id, kind, confidence,
                                   source, confirmed)
                VALUES (\(uid), \(id), \(from), \(to), 'relates', 0.9, 't2Model', true)
                """)
        }

        // Confirming through the store makes the user the source.
        #expect(try await store.confirmEdge(seed.edge.id))
        let confirmed = try #require(try await store.edges().first)
        #expect(confirmed.confirmed && confirmed.source == .user)
    }

    @Test func edgeShapeIsEnforced() async throws {
        let store = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: store)

        // `serves` must point at a goal; an item id is not one.
        await expectSQLState("23503") {
            try await store.insertEdge(
                Edge(
                    id: newID(), from: seed.item.id, to: seed.other.id, kind: .serves,
                    source: .t0Rule))
        }
        // `blocks` must point at an item; a goal id is not one.
        await expectSQLState("23503") {
            try await store.insertEdge(
                Edge(
                    id: newID(), from: seed.item.id, to: seed.goal.id, kind: .blocks,
                    source: .t0Rule))
        }
        // No self-loops.
        await expectSQLState("23514") {
            try await store.insertEdge(
                Edge(
                    id: newID(), from: seed.item.id, to: seed.item.id, kind: .relates,
                    source: .t0Rule))
        }
        // No duplicate edge of the same kind between the same pair.
        await expectSQLState("23505") {
            try await store.insertEdge(
                Edge(
                    id: newID(), from: seed.item.id, to: seed.other.id, kind: .blocks,
                    source: .t2Model))
        }
        // A valid `serves` edge is accepted.
        try await store.insertEdge(
            Edge(id: newID(), from: seed.item.id, to: seed.goal.id, kind: .serves, source: .user))
    }

    @Test func idsMustBeULIDs() async throws {
        let store = try await TestDatabase.newUser()
        let db = try await TestDatabase.get()
        let uid = store.user.rawValue
        await expectSQLState("23514") {
            try await db.client.query(
                """
                INSERT INTO goals (user_id, id, title, status, created_at)
                VALUES (\(uid), 'not-a-ulid', 'x', 'active', now())
                """)
        }
    }

    @Test func newUsersDefaultToIndianTime() async throws {
        let store = try await TestDatabase.newUser()
        #expect(try await store.timezone() == "Asia/Kolkata")
    }
}
