import API
import BrainCore
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Storage
import TestDatabase
import Worker
import Testing

@testable import App

let now = Date(timeIntervalSince1970: 1_795_000_000)

/// One signed-in user talking to the API.
struct Caller {
    let id = UUID()
    func store() async throws -> UserStore { try await TestDatabase.get().scoped(to: UserID(id)) }

    func send(
        _ client: some TestClientProtocol, _ method: HTTPRequest.Method, _ uri: String,
        json: (any Sendable)? = nil
    ) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
        var headers: HTTPFields = [.authorization: "Bearer good-\(id.uuidString)"]
        var buffer: ByteBuffer?
        if let json {
            headers[.contentType] = "application/json"
            buffer = ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: json))
        }
        return try await client.execute(uri: uri, method: method, headers: headers, body: buffer) {
            response in
            let data = Data(buffer: response.body)
            let body =
                data.isEmpty
                ? [:]
                : (try JSONSerialization.jsonObject(with: data) as? [String: Any])
                    ?? [:]
            return (response.status, body)
        }
    }

    /// Raw bytes, for malformed-JSON tests.
    func sendRaw(_ client: some TestClientProtocol, _ uri: String, _ raw: String) async throws
        -> HTTPResponse.Status
    {
        try await client.execute(
            uri: uri, method: .post,
            headers: [
                .authorization: "Bearer good-\(id.uuidString)", .contentType: "application/json",
            ],
            body: ByteBuffer(string: raw)
        ) { $0.status }
    }
}

func newCapture(text: String = "call bank re loan", at date: Date? = nil) -> [String: any Sendable]
{
    var json: [String: any Sendable] = ["id": newID().rawValue, "text": text]
    if let date { json["capturedAt"] = ISO8601DateFormatter().string(from: date) }
    return json
}

@Suite("Me")
struct MeTests {
    @Test func firstCallCreatesTheUserInIndianTime() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let (status, body) = try await me.send(client, .get, "/v1/me")
            #expect(status == .ok)
            #expect(body["userId"] as? String == me.id.uuidString.lowercased())
            #expect(body["timezone"] as? String == "Asia/Kolkata")
        }
    }

    @Test func timezoneMustBeARealIANAName() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let good = try await me.send(
                client, .patch, "/v1/me", json: ["timezone": "Europe/London"])
            #expect(good.status == .ok)
            #expect(good.body["timezone"] as? String == "Europe/London")

            let bad = try await me.send(
                client, .patch, "/v1/me", json: ["timezone": "Mars/Olympus"])
            #expect(bad.status == .badRequest)
            #expect(bad.body["code"] as? String == "invalid_timezone")
        }
    }
}

@Suite("Captures")
struct CaptureTests {
    @Test func createIsStoredAndRetryIsSafe() async throws {
        let me = Caller()
        let capture = newCapture(text: "original")
        try await testApp(clock: { now }).test(.router) { client in
            let first = try await me.send(client, .post, "/v1/captures", json: capture)
            #expect(first.status == .created)
            #expect(first.body["status"] as? String == "raw")

            var retry = capture
            retry["text"] = "changed on retry"
            let second = try await me.send(client, .post, "/v1/captures", json: retry)
            #expect(second.status == .ok)
            #expect(second.body["text"] as? String == "original")
        }
        let stored = try await me.store().captures()
        #expect(stored.count == 1)
    }

    @Test func newCaptureIsQueuedOnceAndARetryIsNot() async throws {
        let me = Caller()
        let enqueuer = RecordingEnqueuer()
        let capture = newCapture()
        try await testApp(enrichment: enqueuer).test(.router) { client in
            _ = try await me.send(client, .post, "/v1/captures", json: capture)
            _ = try await me.send(client, .post, "/v1/captures", json: capture)
        }
        #expect(await enqueuer.queued.map(\.rawValue) == [capture["id"] as! String])
    }

    @Test func textIsStoredVerbatim() async throws {
        let me = Caller()
        let text = "  kal  bank jaana hai\n50K loan ka   form  "
        try await testApp().test(.router) { client in
            let r = try await me.send(client, .post, "/v1/captures", json: newCapture(text: text))
            #expect(r.body["text"] as? String == text)
        }
    }

    @Test func futureTimeBecomesNowPastTimeIsKept() async throws {
        let me = Caller()
        try await testApp(clock: { now }).test(.router) { client in
            let future = try await me.send(
                client, .post, "/v1/captures", json: newCapture(at: now.addingTimeInterval(86400)))
            #expect(future.status == .created)
            #expect(future.body["capturedAt"] as? String == "2026-11-18T11:06:40Z")

            let offline = now.addingTimeInterval(-3 * 86400)
            let past = try await me.send(
                client, .post, "/v1/captures", json: newCapture(at: offline))
            #expect(past.body["capturedAt"] as? String == "2026-11-15T11:06:40Z")
        }
    }

    @Test func lengthLimitsCountCharactersNotBytes() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            // 20,000 Devanagari characters is 60,000 bytes and still allowed.
            let atLimit = String(repeating: "क", count: 20_000)
            #expect(
                try await me.send(client, .post, "/v1/captures", json: newCapture(text: atLimit))
                    .status == .created)

            let over = try await me.send(
                client, .post, "/v1/captures",
                json: newCapture(text: String(repeating: "a", count: 20_001)))
            #expect(over.status == .badRequest)
            #expect(over.body["code"] as? String == "text_too_long")

            let empty = try await me.send(client, .post, "/v1/captures", json: newCapture(text: ""))
            #expect(empty.body["code"] as? String == "empty_text")
        }
    }

    @Test(arguments: ["not-a-ulid", "01arz3ndektsv4rrffq69g5fav", "01ARZ3NDEKTSV4RRFFQ69G5FA", ""])
    func idMustBeAnUppercaseULID(_ id: String) async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let r = try await me.send(
                client, .post, "/v1/captures", json: ["id": id, "text": "x"])
            #expect(r.status == .badRequest)
            #expect(r.body["code"] as? String == "invalid_id")
        }
    }

    @Test func malformedRequestsAre400Not500() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let badSource = #"{"id":"\#(newID().rawValue)","text":"x","source":"telepathy"}"#
            for raw in ["{not json", #"{"text":"no id"}"#, badSource] {
                let status = try await me.sendRaw(client, "/v1/captures", raw)
                #expect(status == .badRequest, "\(raw)")
            }
        }
    }

    @Test func pagesWalkEveryCaptureOnce() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            var created: [String] = []
            for i in 0..<5 {
                let r = try await me.send(
                    client, .post, "/v1/captures", json: newCapture(text: "c\(i)"))
                created.append(r.body["id"] as! String)
            }
            var seen: [String] = []
            var cursor: String?
            var pages = 0
            repeat {
                let uri = "/v1/captures?limit=2" + (cursor.map { "&after=\($0)" } ?? "")
                let r = try await me.send(client, .get, uri)
                seen += (r.body["captures"] as! [[String: Any]]).map { $0["id"] as! String }
                cursor = r.body["nextCursor"] as? String
                pages += 1
            } while cursor != nil
            #expect(seen == created.sorted())
            #expect(pages == 3)
        }
    }

    @Test(arguments: ["limit=0", "limit=501", "after=nope"])
    func badPagingIs400(_ query: String) async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let status = try await me.send(client, .get, "/v1/captures?\(query)").status
            #expect(status == .badRequest)
        }
    }

    @Test func statusFilter() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            let a = try await me.send(client, .post, "/v1/captures", json: newCapture())
            _ = try await me.send(client, .post, "/v1/captures", json: newCapture())
            try await me.store().setCaptureStatus(ULID(a.body["id"] as! String)!, .failed)
            let r = try await me.send(client, .get, "/v1/captures?status=failed")
            #expect((r.body["captures"] as! [[String: Any]]).count == 1)
        }
    }
}

@Suite("Isolation over HTTP")
struct HTTPIsolationTests {
    /// Another user's id and an id that never existed must be indistinguishable.
    @Test func otherUsersCaptureLooksExactlyLikeAMissingOne() async throws {
        let alice = Caller()
        let bob = Caller()
        try await testApp().test(.router) { client in
            let made = try await alice.send(client, .post, "/v1/captures", json: newCapture())
            let id = made.body["id"] as! String

            let theirs = try await bob.send(client, .get, "/v1/captures/\(id)")
            let missing = try await bob.send(client, .get, "/v1/captures/\(newID().rawValue)")
            #expect(theirs.status == .notFound)
            #expect(missing.status == .notFound)
            #expect(theirs.body as NSDictionary == missing.body as NSDictionary)

            let list = try await bob.send(client, .get, "/v1/captures")
            #expect((list.body["captures"] as! [Any]).isEmpty)
        }
    }

    @Test func otherUsersGoalCannotBeChanged() async throws {
        let alice = Caller()
        let bob = Caller()
        try await testApp().test(.router) { client in
            let id = newID().rawValue
            _ = try await alice.send(client, .post, "/v1/goals", json: ["id": id, "title": "A's"])
            let r = try await bob.send(client, .patch, "/v1/goals/\(id)", json: ["title": "B's"])
            #expect(r.status == .notFound)
            let still = try await alice.send(client, .get, "/v1/goals")
            #expect((still.body["goals"] as! [[String: Any]]).first?["title"] as? String == "A's")
        }
    }

    @Test func otherUsersItemIsNotFound() async throws {
        let alice = Caller()
        let bob = Caller()
        let item = Item(id: newID(), title: "alice's", createdAt: now)
        try await testApp().test(.router) { client in
            _ = try await alice.send(client, .get, "/v1/me")  // creates the user row
            try await alice.store().insertItem(item)
            #expect(
                try await alice.send(client, .get, "/v1/items/\(item.id.rawValue)").status == .ok)
            #expect(
                try await bob.send(client, .get, "/v1/items/\(item.id.rawValue)").status
                    == .notFound)
        }
    }
}

@Suite("Items and goals")
struct ItemGoalTests {
    /// Items are created by enrichment (S4). Until then, insert one directly
    /// and check the API shows every classified field as stored.
    @Test func itemShowsWhoDecidedEachField() async throws {
        let me = Caller()
        let item = Item(
            id: newID(), title: "call bank",
            type: Classified(.task, confidence: 0.9, tier: .t0, evidence: Span(start: 0, end: 4)),
            effort: Classified(.small, confidence: 0.6, tier: .t2),
            category: Classified(.deepWork, confidence: 1, tier: .user), createdAt: now)
        try await testApp().test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            try await me.store().insertItem(item)
            let r = try await me.send(client, .get, "/v1/items/\(item.id.rawValue)")
            let type = r.body["type"] as! [String: Any]
            #expect(type["value"] as? String == "task")
            #expect(type["decidedBy"] as? String == "t0")
            #expect((type["evidence"] as? [String: Int]) == ["start": 0, "end": 4])
            #expect((r.body["effort"] as! [String: Any])["decidedBy"] as? String == "t2")
            #expect((r.body["category"] as! [String: Any])["value"] as? String == "deepWork")
            // Unknown is an absent value, not an error.
            #expect((r.body["dueAt"] as! [String: Any])["value"] == nil)
        }
    }

    @Test func goalCreateRetryAndUpdate() async throws {
        let me = Caller()
        let id = newID().rawValue
        try await testApp().test(.router) { client in
            let first = try await me.send(
                client, .post, "/v1/goals", json: ["id": id, "title": "Fit"])
            #expect(first.status == .created)
            let retry = try await me.send(
                client, .post, "/v1/goals", json: ["id": id, "title": "x"])
            #expect(retry.status == .ok)
            #expect(retry.body["title"] as? String == "Fit")

            let done = try await me.send(
                client, .patch, "/v1/goals/\(id)", json: ["status": "achieved"])
            #expect(done.body["status"] as? String == "achieved")
            #expect(done.body["title"] as? String == "Fit")

            let long = try await me.send(
                client, .patch, "/v1/goals/\(id)",
                json: ["title": String(repeating: "g", count: 501)])
            #expect(long.body["code"] as? String == "title_too_long")
        }
    }
}

@Suite("Later steps answer 501")
struct NotYetTests {
    @Test(arguments: [
        (HTTPRequest.Method.get, "/v1/plan"), (.get, "/v1/edges"), (.get, "/v1/questions"),
    ])
    func notImplementedYet(_ method: HTTPRequest.Method, _ uri: String) async throws {
        try await testApp().test(.router) { client in
            let r = try await Caller().send(client, method, uri)
            #expect(r.status == .notImplemented)
            #expect(r.body["code"] as? String == "not_implemented")
        }
    }
}

/// Every Brain enum value must have an API counterpart and come back as
/// itself, or `convert` would crash on real data.
@Suite("API matches Brain's enums")
struct APIDriftTests {
    func roundTrips<B: CaseIterable & RawRepresentable, A: CaseIterable & RawRepresentable>(
        _: B.Type, _: A.Type
    ) -> Bool where B.RawValue == String, A.RawValue == String {
        Set(B.allCases.map(\.rawValue)) == Set(A.allCases.map(\.rawValue))
    }

    @Test func everyEnumMatches() {
        #expect(roundTrips(Tier.self, Components.Schemas.DecidedBy.self))
        #expect(roundTrips(CaptureSource.self, Components.Schemas.CaptureSource.self))
        #expect(roundTrips(CaptureStatus.self, Components.Schemas.CaptureStatus.self))
        #expect(roundTrips(ItemType.self, Components.Schemas.ItemType.self))
        #expect(roundTrips(ItemStatus.self, Components.Schemas.ItemStatus.self))
        #expect(roundTrips(EffortBucket.self, Components.Schemas.Effort.self))
        #expect(roundTrips(TaskCategory.self, Components.Schemas.Category.self))
        #expect(roundTrips(GoalStatus.self, Components.Schemas.GoalStatus.self))
        #expect(roundTrips(EdgeKind.self, Components.Schemas.EdgeKind.self))
        #expect(roundTrips(EdgeSource.self, Components.Schemas.EdgeSuggestedBy.self))
    }
}
