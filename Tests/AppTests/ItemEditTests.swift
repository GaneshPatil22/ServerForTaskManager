import BrainCore
import Foundation
import HummingbirdTesting
import Storage
import TestDatabase
import Testing

@testable import App

@Suite("Item edits")
struct ItemEditTests {
    /// An item the worker made: T0 type, a T2 effort guess, from a capture.
    func seeded(_ me: Caller, _ client: some TestClientProtocol) async throws -> Item {
        _ = try await me.send(client, .get, "/v1/me")
        let store = try await me.store()
        let capture = Capture(id: newID(), rawText: "call the bank", createdAt: now)
        _ = try await store.insertCapture(capture)
        let item = Item(
            id: newID(), captureId: capture.id, title: "call the bank",
            type: Classified(.task, confidence: 0.9, tier: .t0),
            effort: Classified(.small, confidence: 0.6, tier: .t2), createdAt: now)
        try await store.insertItem(item)
        return item
    }

    func uri(_ item: Item) -> String { "/v1/items/\(item.id.rawValue)" }

    @Test func changedFieldBecomesTheUsersAndIsRecordedAgainstTheTier() async throws {
        let me = Caller()
        try await testApp(clock: { now }).test(.router) { client in
            let item = try await seeded(me, client)
            let r = try await me.send(client, .patch, uri(item), json: ["effort": "large"])
            #expect(r.status == .ok)
            let effort = r.body["effort"] as! [String: Any]
            #expect(effort["value"] as? String == "large")
            #expect(effort["decidedBy"] as? String == "user")
            #expect(effort["confidence"] as? Double == 1)

            let correction = try #require(try await me.store().corrections().first)
            #expect(correction.field == "effort")
            #expect(correction.beforeValue == "small")
            #expect(correction.afterValue == "large")
            #expect(correction.tier == .t2, "the tier that got it wrong")
        }
    }

    @Test func sendingTheSameValueChangesNothing() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let item = try await seeded(me, client)
            let r = try await me.send(client, .patch, uri(item), json: ["type": "task"])
            #expect((r.body["type"] as! [String: Any])["decidedBy"] as? String == "t0")
            #expect(try await me.store().corrections().isEmpty)
        }
    }

    @Test func finishingAnItemIsNotACorrection() async throws {
        let me = Caller()
        try await testApp(clock: { now }).test(.router) { client in
            let item = try await seeded(me, client)
            let r = try await me.send(client, .patch, uri(item), json: ["status": "done"])
            #expect(r.body["status"] as? String == "done")
            #expect(try await me.store().corrections().isEmpty)
            let plan = try await me.send(client, .get, "/v1/plan")
            #expect(ids(plan.body["ranked"]).isEmpty)
        }
    }

    @Test func titleChangeOnADerivedTitleIsACorrection() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let item = try await seeded(me, client)
            _ = try await me.send(client, .patch, uri(item), json: ["title": "call HDFC re loan"])
            let correction = try #require(try await me.store().corrections().first)
            #expect(correction.field == "title")
            #expect(correction.tier == .t0)
        }
    }

    @Test func multiFieldEditIsAtomicAndAUnknownGoalRollsItAllBack() async throws {
        let me = Caller()
        let bob = Caller()
        try await testApp().test(.router) { client in
            let item = try await seeded(me, client)
            let bobsGoal = newID().rawValue
            _ = try await bob.send(
                client, .post, "/v1/goals", json: ["id": bobsGoal, "title": "B"])

            let refused = try await me.send(
                client, .patch, uri(item),
                json: ["effort": "large", "category": "money", "goalId": bobsGoal])
            #expect(refused.status == .notFound)
            #expect(try await me.store().corrections().isEmpty, "nothing half-applied")
            #expect(try await me.store().item(item.id)?.effort.value == .small)

            let myGoal = newID().rawValue
            _ = try await me.send(
                client, .post, "/v1/goals", json: ["id": myGoal, "title": "Money"])
            let ok = try await me.send(
                client, .patch, uri(item),
                json: ["effort": "large", "category": "money", "goalId": myGoal])
            #expect(ok.status == .ok)
            #expect(try await me.store().corrections().count == 3)
        }
    }

    @Test func dueDateFromTheUserIsTheUsers() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let item = try await seeded(me, client)
            let r = try await me.send(
                client, .patch, uri(item), json: ["dueAt": "2026-12-01T10:00:00Z"])
            let due = r.body["dueAt"] as! [String: Any]
            #expect(due["value"] as? String == "2026-12-01T10:00:00.000Z")
            #expect(due["decidedBy"] as? String == "user")
        }
    }

    @Test func otherUsersItemAndBadInput() async throws {
        let me = Caller()
        let bob = Caller()
        try await testApp().test(.router) { client in
            let item = try await seeded(me, client)
            let theirs = try await bob.send(client, .patch, uri(item), json: ["status": "done"])
            #expect(theirs.status == .notFound)
            #expect(try await me.store().item(item.id)?.status == .open)

            let long = try await me.send(
                client, .patch, uri(item), json: ["title": String(repeating: "x", count: 501)])
            #expect(long.body["code"] as? String == "title_too_long")
            let badGoal = try await me.send(client, .patch, uri(item), json: ["goalId": "nope"])
            #expect(badGoal.body["code"] as? String == "invalid_id")
        }
    }
}
