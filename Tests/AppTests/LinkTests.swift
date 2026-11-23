import BrainCore
import Foundation
import HummingbirdTesting
import Storage
import TestDatabase
import Testing

@testable import App

/// A user with two items, and optionally a suggestion between them.
struct LinkFixture {
    let me = Caller()
    let a = Item(id: newID(), title: "get client approval", createdAt: now)
    let b = Item(id: newID(), title: "send invoice", createdAt: now)

    func setUp(_ client: some TestClientProtocol, suggest: Bool = false) async throws -> Edge? {
        _ = try await me.send(client, .get, "/v1/me")
        let store = try await me.store()
        try await store.insertItem(a)
        try await store.insertItem(b)
        guard suggest else { return nil }
        let suggestion = Edge(
            id: newID(), from: a.id, to: b.id, kind: .blocks, confidence: 0.8, source: .t0Rule)
        try await store.insertEdge(suggestion)
        return suggestion
    }

    func link(_ from: Item, _ to: Item, _ kind: String = "blocks") -> [String: any Sendable] {
        ["id": newID().rawValue, "from": from.id.rawValue, "to": to.id.rawValue, "kind": kind]
    }
}

@Suite("Links")
struct LinkTests {
    @Test func userLinkIsConfirmedAndRetrySafe() async throws {
        let f = LinkFixture()
        try await testApp().test(.router) { client in
            _ = try await f.setUp(client)
            let body = f.link(f.a, f.b)
            let first = try await f.me.send(client, .post, "/v1/edges", json: body)
            #expect(first.status == .created)
            #expect(first.body["confirmed"] as? Bool == true)
            #expect(first.body["suggestedBy"] as? String == "user")
            let retry = try await f.me.send(client, .post, "/v1/edges", json: body)
            #expect(retry.status == .ok)
        }
    }

    @Test func refusals() async throws {
        let f = LinkFixture()
        let stranger = Item(id: newID(), title: "not mine", createdAt: now)
        try await testApp().test(.router) { client in
            _ = try await f.setUp(client)
            _ = try await f.me.send(client, .post, "/v1/edges", json: f.link(f.a, f.b))

            let loop = try await f.me.send(client, .post, "/v1/edges", json: f.link(f.b, f.a))
            #expect(loop.status == .conflict)
            #expect(loop.body["code"] as? String == "cycle")

            let selfLink = try await f.me.send(client, .post, "/v1/edges", json: f.link(f.a, f.a))
            #expect(selfLink.body["code"] as? String == "self_link")

            let serves = try await f.me.send(
                client, .post, "/v1/edges", json: f.link(f.a, f.b, "serves"))
            #expect(serves.body["code"] as? String == "wrong_target")

            let foreign = try await f.me.send(
                client, .post, "/v1/edges", json: f.link(f.a, stranger))
            #expect(foreign.status == .notFound)
        }
    }

    @Test func confirmingASuggestionRecordsWhoWasRight() async throws {
        let f = LinkFixture()
        try await testApp().test(.router) { client in
            let suggestion = try #require(try await f.setUp(client, suggest: true))
            let uri = "/v1/edges/\(suggestion.id.rawValue)/confirm"
            let r = try await f.me.send(client, .post, uri)
            #expect(r.status == .ok)
            #expect(r.body["confirmed"] as? Bool == true)
            #expect(r.body["suggestedBy"] as? String == "user")
            _ = try await f.me.send(client, .post, uri)  // again: no second correction

            let corrections = try await f.me.store().corrections()
            #expect(corrections.count == 1)
            #expect(corrections.first?.field == "confirmed")
            #expect(corrections.first?.tier == .t0, "the tier that suggested it")
        }
    }

    @Test func rejectingASuggestionRemovesItAndUnblocksThePlan() async throws {
        let f = LinkFixture()
        try await testApp(clock: { now }).test(.router) { client in
            let suggestion = try #require(try await f.setUp(client, suggest: true))
            let before = try await f.me.send(client, .get, "/v1/plan")
            #expect((before.body["blocked"] as! [Any]).count == 1)

            let r = try await f.me.send(
                client, .post, "/v1/edges/\(suggestion.id.rawValue)/reject")
            #expect(r.status == .noContent)
            #expect(
                (try await f.me.send(client, .get, "/v1/edges").body["edges"] as! [Any]).isEmpty)
            let after = try await f.me.send(client, .get, "/v1/plan")
            #expect((after.body["blocked"] as! [Any]).isEmpty)

            let correction = try #require(try await f.me.store().corrections().first)
            #expect(correction.field == "rejected")
            #expect(correction.tier == .t0)
            let again = try await f.me.send(
                client, .post, "/v1/edges/\(suggestion.id.rawValue)/reject")
            #expect(again.status == .notFound)
        }
    }

    @Test func userCanLaterMakeALinkTheyRejected() async throws {
        let f = LinkFixture()
        try await testApp().test(.router) { client in
            let suggestion = try #require(try await f.setUp(client, suggest: true))
            _ = try await f.me.send(client, .post, "/v1/edges/\(suggestion.id.rawValue)/reject")
            let made = try await f.me.send(client, .post, "/v1/edges", json: f.link(f.a, f.b))
            #expect(made.status == .created)
            let live = try await f.me.store().edges()
            #expect(live.count == 1)
            #expect(live.first?.confirmed == true)
        }
    }

    @Test func writingTheSuggestedLinkConfirmsIt() async throws {
        let f = LinkFixture()
        try await testApp().test(.router) { client in
            let suggestion = try #require(try await f.setUp(client, suggest: true))
            let r = try await f.me.send(client, .post, "/v1/edges", json: f.link(f.a, f.b))
            #expect(r.status == .ok)
            #expect(r.body["id"] as? String == suggestion.id.rawValue)
            #expect(r.body["confirmed"] as? Bool == true)
            #expect(try await f.me.store().corrections().count == 1)
        }
    }

    @Test func anotherUsersLinksCannotBeTouched() async throws {
        let f = LinkFixture()
        let bob = Caller()
        try await testApp().test(.router) { client in
            let suggestion = try #require(try await f.setUp(client, suggest: true))
            let id = suggestion.id.rawValue
            #expect(
                try await bob.send(client, .post, "/v1/edges/\(id)/confirm").status == .notFound)
            #expect(try await bob.send(client, .post, "/v1/edges/\(id)/reject").status == .notFound)
            #expect((try await bob.send(client, .get, "/v1/edges").body["edges"] as! [Any]).isEmpty)
            #expect(try await f.me.store().edge(suggestion.id)?.confirmed == false)
        }
    }

    @Test func confirmedFilter() async throws {
        let f = LinkFixture()
        try await testApp().test(.router) { client in
            _ = try await f.setUp(client, suggest: true)
            let c = Item(id: newID(), title: "third", createdAt: now)
            try await f.me.store().insertItem(c)
            _ = try await f.me.send(client, .post, "/v1/edges", json: f.link(f.b, c))
            let confirmed = try await f.me.send(client, .get, "/v1/edges?confirmed=true")
            let pending = try await f.me.send(client, .get, "/v1/edges?confirmed=false")
            #expect((confirmed.body["edges"] as! [Any]).count == 1)
            #expect((pending.body["edges"] as! [Any]).count == 1)
        }
    }
}
