import BrainCore
import Foundation
import Testing

@testable import Storage

/// The cross-user isolation suite (ADR-0007). User B tries to read, change and
/// link to user A's data by id. Every attempt must see nothing or be refused.
@Suite("Cross-user isolation")
struct IsolationTests {
    @Test func otherUserSeesNothing() async throws {
        let a = try await TestDatabase.newUser()
        let b = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: a)

        #expect(try await b.captures().isEmpty)
        #expect(try await b.items().isEmpty)
        #expect(try await b.goals().isEmpty)
        #expect(try await b.edges().isEmpty)
        #expect(try await b.corrections().isEmpty)
        // Knowing the exact id does not help.
        #expect(try await b.capture(seed.capture.id) == nil)
        #expect(try await b.item(seed.item.id) == nil)

        // And A still sees all of it.
        #expect(try await a.captures().count == 1)
        #expect(try await a.items().count == 2)
    }

    @Test func otherUserCannotChangeAnything() async throws {
        let a = try await TestDatabase.newUser()
        let b = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: a)

        #expect(try await b.setCaptureStatus(seed.capture.id, .failed) == false)
        #expect(try await b.setItemStatus(seed.item.id, .done, at: fixedDate) == false)
        #expect(try await b.confirmEdge(seed.edge.id) == false)

        #expect(try await a.capture(seed.capture.id)?.status == .raw)
        #expect(try await a.item(seed.item.id)?.status == .open)
        #expect(try await a.edges().first?.confirmed == false)
    }

    @Test func otherUserCannotLinkToForeignRows() async throws {
        let a = try await TestDatabase.newUser()
        let b = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: a)
        let own = Item(id: newID(), title: "b's own item", createdAt: fixedDate)
        try await b.insertItem(own)

        // Edges to and from A's items, and to A's goal.
        await expectSQLState("23503") {
            try await b.insertEdge(
                Edge(id: newID(), from: own.id, to: seed.item.id, kind: .blocks, source: .t0Rule))
        }
        await expectSQLState("23503") {
            try await b.insertEdge(
                Edge(id: newID(), from: seed.item.id, to: own.id, kind: .blocks, source: .t0Rule))
        }
        await expectSQLState("23503") {
            try await b.insertEdge(
                Edge(id: newID(), from: own.id, to: seed.goal.id, kind: .serves, source: .user))
        }
        // An item claiming A's capture or A's goal.
        await expectSQLState("23503") {
            try await b.insertItem(
                Item(id: newID(), captureId: seed.capture.id, title: "x", createdAt: fixedDate))
        }
        await expectSQLState("23503") {
            try await b.insertItem(
                Item(
                    id: newID(), title: "x",
                    goalId: Classified(seed.goal.id, confidence: 1, tier: .t0),
                    createdAt: fixedDate))
        }
        #expect(try await a.edges().count == 1)
    }

    /// Keys are per user, so one user cannot learn that another user's id or
    /// idempotency key exists by colliding with it.
    @Test func sameIdsAndKeysDoNotCollideAcrossUsers() async throws {
        let a = try await TestDatabase.newUser()
        let b = try await TestDatabase.newUser()
        let id = newID()

        let fromA = try await a.insertCapture(
            Capture(id: id, rawText: "A's text", createdAt: fixedDate, idempotencyKey: "k1"))
        let fromB = try await b.insertCapture(
            Capture(id: id, rawText: "B's text", createdAt: fixedDate, idempotencyKey: "k1"))

        #expect(fromA.created && fromB.created)
        #expect(try await a.capture(id)?.rawText == "A's text")
        #expect(try await b.capture(id)?.rawText == "B's text")
    }

    @Test func writesRequireAKnownUser() async throws {
        let db = try await TestDatabase.get()
        let stranger = db.scoped(to: UserID(UUID()))  // never ensureUser()'d
        await expectSQLState("23503") {
            _ = try await stranger.insertCapture(
                Capture(id: newID(), rawText: "x", createdAt: fixedDate))
        }
    }
}
