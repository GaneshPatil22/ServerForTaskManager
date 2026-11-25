import BrainCore
import Foundation
import HummingbirdTesting
import Storage
import TestDatabase
import Testing

@testable import App

@Suite("Comments and count goals API")
struct CommentAPITests {
    @Test func commentOnAnItemGoalAndCommitment() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            let item = Item(id: newID(), title: "call bank", createdAt: mondayEarlyIST)
            try await me.store().insertItem(item)
            let goal = try await me.send(
                client, .post, "/v1/goals", json: ["id": newID().rawValue, "title": "learn"])
            let goalId = try #require(goal.body["id"] as? String)

            let id = newID().rawValue
            let created = try await me.send(
                client, .post, "/v1/comments",
                json: ["id": id, "itemId": item.id.rawValue, "body": "they said Monday"])
            #expect(created.status == .created)
            #expect(created.body["itemId"] as? String == item.id.rawValue)
            #expect(created.body["goalId"] == nil)
            let retry = try await me.send(
                client, .post, "/v1/comments",
                json: ["id": id, "itemId": item.id.rawValue, "body": "they said Monday"])
            #expect(retry.status == .ok)
            _ = try await me.send(
                client, .post, "/v1/comments",
                json: ["id": newID().rawValue, "goalId": goalId, "body": "Q4 only"])

            let list = try await me.send(
                client, .get, "/v1/comments?itemId=\(item.id.rawValue)")
            let comments = try #require(list.body["comments"] as? [[String: Any]])
            #expect(comments.map { $0["body"] as? String } == ["they said Monday"])

            let edited = try await me.send(
                client, .patch, "/v1/comments/\(id)", json: ["body": "Monday, 11am"])
            #expect(edited.body["body"] as? String == "Monday, 11am")
            #expect(try await me.send(client, .delete, "/v1/comments/\(id)").status == .noContent)
            #expect(try await me.send(client, .delete, "/v1/comments/\(id)").status == .notFound)
        }
    }

    @Test func aCommentNamesExactlyOneRealThing() async throws {
        let me = Caller()
        try await testApp().test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            let none = try await me.send(
                client, .post, "/v1/comments", json: ["id": newID().rawValue, "body": "x"])
            #expect(code(none.body) == "one_target")
            let two = try await me.send(
                client, .post, "/v1/comments",
                json: [
                    "id": newID().rawValue, "itemId": newID().rawValue,
                    "goalId": newID().rawValue, "body": "x",
                ])
            #expect(code(two.body) == "one_target")
            let missing = try await me.send(
                client, .post, "/v1/comments",
                json: ["id": newID().rawValue, "itemId": newID().rawValue, "body": "x"])
            #expect(missing.status == .notFound)
            let list = try await me.send(client, .get, "/v1/comments")
            #expect(code(list.body) == "one_target")
            let long = try await me.send(
                client, .post, "/v1/comments",
                json: [
                    "id": newID().rawValue, "itemId": newID().rawValue,
                    "body": String(repeating: "a", count: 2001),
                ])
            #expect(code(long.body) == "body_too_long")
        }
    }

    @Test func anotherUsersCommentsAreUnreachable() async throws {
        let me = Caller()
        let them = Caller()
        try await testApp().test(.router) { client in
            _ = try await them.send(client, .get, "/v1/me")
            let item = Item(id: newID(), title: "theirs", createdAt: mondayEarlyIST)
            try await them.store().insertItem(item)
            let id = newID().rawValue
            _ = try await them.send(
                client, .post, "/v1/comments",
                json: ["id": id, "itemId": item.id.rawValue, "body": "private"])

            let list = try await me.send(client, .get, "/v1/comments?itemId=\(item.id.rawValue)")
            #expect((list.body["comments"] as? [Any])?.isEmpty == true)
            let onTheirs = try await me.send(
                client, .post, "/v1/comments",
                json: ["id": newID().rawValue, "itemId": item.id.rawValue, "body": "x"])
            #expect(onTheirs.status == .notFound)
            #expect(
                try await me.send(client, .patch, "/v1/comments/\(id)", json: ["body": "x"]).status
                    == .notFound)
            #expect(try await me.send(client, .delete, "/v1/comments/\(id)").status == .notFound)
        }
    }

    @Test func countGoalCircles() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            let goal = try await me.send(
                client, .post, "/v1/goals",
                json: [
                    "id": newID().rawValue, "title": "Finish 6 big books", "period": "2026-Q4",
                    "targetCount": 2,
                ] as [String: any Sendable])
            #expect(goal.status == .created)
            #expect(goal.body["targetCount"] as? Int == 2 && goal.body["doneCount"] as? Int == 0)
            let goalId = try #require(goal.body["id"] as? String)
            let marks = "/v1/goals/\(goalId)/marks"

            // Today by default (Monday 23 Nov in the user's zone), with a note.
            let first = try await me.send(
                client, .post, marks, json: ["id": newID().rawValue, "note": "Atomic Habits"])
            #expect(first.status == .created && first.body["day"] as? String == "2026-11-23")
            let future = try await me.send(
                client, .post, marks, json: ["id": newID().rawValue, "day": "2026-11-24"])
            #expect(code(future.body) == "in_future")
            _ = try await me.send(
                client, .post, marks, json: ["id": newID().rawValue, "day": "2026-11-20"])
            let full = try await me.send(client, .post, marks, json: ["id": newID().rawValue])
            #expect(full.status == .conflict && code(full.body) == "target_reached")

            let listed = try await me.send(client, .get, "/v1/goals")
            let row = (listed.body["goals"] as? [[String: Any]])?.first
            #expect(row?["doneCount"] as? Int == 2)
            #expect(row?["status"] as? String == "active", "filling is not achieving")

            let lower = try await me.send(
                client, .patch, "/v1/goals/\(goalId)", json: ["targetCount": 1])
            #expect(code(lower.body) == "target_below_done")
            let cleared = try await me.send(
                client, .patch, "/v1/goals/\(goalId)",
                json: ["clear": ["targetCount"]] as [String: any Sendable])
            #expect(code(cleared.body) == "target_below_done")
            let raised = try await me.send(
                client, .patch, "/v1/goals/\(goalId)",
                json: ["targetCount": 6, "title": "Finish 6 big books with notes"]
                    as [String: any Sendable])
            #expect(raised.body["targetCount"] as? Int == 6)
            #expect(raised.body["title"] as? String == "Finish 6 big books with notes")

            let markId = try #require(first.body["id"] as? String)
            let noted = try await me.send(
                client, .patch, "\(marks)/\(markId)",
                json: ["clear": ["note"]] as [String: any Sendable])
            #expect(noted.status == .ok && noted.body["note"] == nil)
            #expect(try await me.send(client, .delete, "\(marks)/\(markId)").status == .noContent)
            let after = try await me.send(client, .get, marks)
            #expect((after.body["marks"] as? [Any])?.count == 1)
        }
    }

    @Test func ordinaryGoalsAndBadTargets() async throws {
        let me = Caller()
        let them = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            let plain = try await me.send(
                client, .post, "/v1/goals", json: ["id": newID().rawValue, "title": "job"])
            #expect(plain.body["targetCount"] == nil && plain.body["doneCount"] == nil)
            let plainId = try #require(plain.body["id"] as? String)
            let mark = try await me.send(
                client, .post, "/v1/goals/\(plainId)/marks", json: ["id": newID().rawValue])
            #expect(code(mark.body) == "not_a_count_goal")

            for bad in [0, 1001] {
                let r = try await me.send(
                    client, .post, "/v1/goals",
                    json: ["id": newID().rawValue, "title": "x", "targetCount": bad]
                        as [String: any Sendable])
                #expect(code(r.body) == "invalid_target", "\(bad)")
            }

            // Someone else's goal is "not found", whatever is asked of it.
            let theirs = try await them.send(
                client, .post, "/v1/goals",
                json: ["id": newID().rawValue, "title": "theirs", "targetCount": 3]
                    as [String: any Sendable])
            let theirId = try #require(theirs.body["id"] as? String)
            let fill = try await me.send(
                client, .post, "/v1/goals/\(theirId)/marks", json: ["id": newID().rawValue])
            #expect(fill.status == .notFound)
            #expect(
                try await me.send(client, .get, "/v1/goals/\(theirId)/marks").status == .notFound)
        }
    }
}
