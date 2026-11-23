import BrainCore
import Foundation
import Storage
import TestDatabase
import Testing

@testable import App

func ids(_ list: Any?) -> [String] {
    (list as? [[String: Any]] ?? []).compactMap { ($0["item"] as? [String: Any])?["id"] as? String }
}

@Suite("Plan")
struct PlanTests {
    @Test func emptyAccountHasNoNextAndNoError() async throws {
        let me = Caller()
        try await testApp(clock: { now }).test(.router) { client in
            let r = try await me.send(client, .get, "/v1/plan")
            #expect(r.status == .ok)
            #expect(r.body["next"] == nil)
            #expect(ids(r.body["ranked"]).isEmpty)
        }
    }

    /// A blocked item may rank high, but is never offered as the thing to do.
    @Test func blockedWorkIsNeverNext() async throws {
        let me = Caller()
        let approval = Item(id: newID(), title: "get client approval", createdAt: now)
        let invoice = Item(
            id: newID(), title: "send invoice",
            dueAt: Classified(now.addingTimeInterval(3600), confidence: 1, tier: .t0),
            createdAt: now)
        try await testApp(clock: { now }).test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            let store = try await me.store()
            try await store.insertItem(approval)
            try await store.insertItem(invoice)
            try await store.insertEdge(
                Edge(
                    id: newID(), from: approval.id, to: invoice.id, kind: .blocks,
                    source: .user, confirmed: true))

            let r = try await me.send(client, .get, "/v1/plan")
            let next = (r.body["next"] as? [String: Any])?["item"] as? [String: Any]
            #expect(next?["id"] as? String == approval.id.rawValue)
            let blocked = r.body["blocked"] as! [[String: Any]]
            #expect(blocked.count == 1)
            #expect((blocked[0]["item"] as! [String: Any])["id"] as? String == invoice.id.rawValue)
            #expect(blocked[0]["blockedBy"] as? [String] == [approval.id.rawValue])
            let why = (r.body["next"] as! [String: Any])["why"] as! [String: Any]
            #expect(why["unblocks"] as? Int == 1)
        }
    }

    @Test func tinyStartableWorkIsAQuickWinAndDoneWorkIsGone() async throws {
        let me = Caller()
        let quick = Item(
            id: newID(), title: "reply to ravi",
            effort: Classified(.tiny, confidence: 1, tier: .t0), createdAt: now)
        let done = Item(id: newID(), title: "already done", status: .done, createdAt: now)
        try await testApp(clock: { now }).test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            try await me.store().insertItem(quick)
            try await me.store().insertItem(done)
            let r = try await me.send(client, .get, "/v1/plan")
            #expect(ids(r.body["quickWins"]) == [quick.id.rawValue])
            #expect(!ids(r.body["ranked"]).contains(done.id.rawValue))
        }
    }

    @Test func sameGraphSameAnswer() async throws {
        let me = Caller()
        try await testApp(clock: { now }).test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            for title in ["a", "b", "c", "d", "e"] {
                try await me.store().insertItem(Item(id: newID(), title: title, createdAt: now))
            }
            let first = ids(try await me.send(client, .get, "/v1/plan").body["ranked"])
            let second = ids(try await me.send(client, .get, "/v1/plan").body["ranked"])
            #expect(first.count == 5)
            #expect(first == second)
        }
    }

    @Test func anotherUsersItemsNeverAppear() async throws {
        let alice = Caller()
        let bob = Caller()
        try await testApp(clock: { now }).test(.router) { client in
            _ = try await alice.send(client, .get, "/v1/me")
            try await alice.store().insertItem(Item(id: newID(), title: "alice's", createdAt: now))
            let r = try await bob.send(client, .get, "/v1/plan")
            #expect(ids(r.body["ranked"]).isEmpty)
        }
    }
}
