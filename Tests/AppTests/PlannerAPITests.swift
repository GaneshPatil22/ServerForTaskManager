import API
import BrainCore
import Foundation
import Hummingbird
import Storage
import TestDatabase
import Testing

@testable import App

/// 02:00 IST on Monday 23 November 2026, which is still Sunday the 22nd in
/// UTC: the case where a server-side "today" shows the wrong day's ritual.
let mondayEarlyIST = Date(timeIntervalSince1970: 1_795_379_400)  // 2026-11-22T20:30:00Z

func commitmentJSON(
    _ rule: [String: any Sendable] = ["kind": "daily"], title: String = "read 10 pages",
    kind: String = "habit", minutes: Int = 20, extra: [String: any Sendable] = [:]
) -> [String: any Sendable] {
    var json: [String: any Sendable] = [
        "id": newID().rawValue, "title": title, "kind": kind, "rule": rule, "minutes": minutes,
        "startOn": "2026-11-01",
    ]
    json.merge(extra) { $1 }
    return json
}

func code(_ body: [String: Any]) -> String? { body["code"] as? String }

func scheduledIDs(_ plan: [String: Any]) -> [String] {
    (plan["commitments"] as? [[String: Any]] ?? []).compactMap {
        ($0["commitment"] as? [String: Any])?["id"] as? String
    }
}

@Suite("Planner API")
struct PlannerAPITests {
    @Test func theDayIsTheUsersNotTheServers() async throws {
        #expect(CalendarDay(mondayEarlyIST, in: TimeZone(identifier: "UTC")!).weekday == .sunday)
        let india = Caller()
        let utc = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            _ = try await utc.send(client, .patch, "/v1/me", json: ["timezone": "UTC"])
            for caller in [india, utc] {
                for (title, weekday) in [("Monday standup", "monday"), ("Sunday review", "sunday")]
                {
                    let r = try await caller.send(
                        client, .post, "/v1/commitments",
                        json: commitmentJSON(
                            ["kind": "weeklyOn", "weekday": weekday], title: title, kind: "ritual"))
                    #expect(r.status == .created)
                }
            }
            func titles(_ caller: Caller) async throws -> (String?, [String]) {
                let plan = try await caller.send(client, .get, "/v1/plan").body
                let titles = (plan["commitments"] as? [[String: Any]] ?? []).compactMap {
                    ($0["commitment"] as? [String: Any])?["title"] as? String
                }
                return (plan["day"] as? String, titles)
            }
            let (indiaDay, indiaTitles) = try await titles(india)
            #expect(indiaDay == "2026-11-23" && indiaTitles == ["Monday standup"])
            let (utcDay, utcTitles) = try await titles(utc)
            #expect(utcDay == "2026-11-22" && utcTitles == ["Sunday review"])
        }
    }

    /// The structural rule: commitments are a section, never rows in `ranked`.
    @Test func commitmentsAreNeverRanked() async throws {
        let me = Caller()
        let item = Item(id: newID(), title: "send invoice", createdAt: mondayEarlyIST)
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            try await me.store().insertItem(item)
            let made = try await me.send(client, .post, "/v1/commitments", json: commitmentJSON())
            let id = made.body["id"] as! String
            let plan = try await me.send(client, .get, "/v1/plan").body
            #expect(ids(plan["ranked"]) == [item.id.rawValue])
            #expect(scheduledIDs(plan) == [id])
            #expect(plan["committedMinutes"] as? Int == 20)
            #expect(
                (plan["next"] as? [String: Any]).flatMap { $0["item"] as? [String: Any] }?["id"]
                    as? String == item.id.rawValue)
        }
    }

    @Test func commitmentCreateRetryAndValidation() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            let json = commitmentJSON(
                ["kind": "monthlyOnDay", "day": 4], title: "Pay rent", kind: "payment",
                minutes: 5, extra: ["note": "22k"])
            let first = try await me.send(client, .post, "/v1/commitments", json: json)
            #expect(first.status == .created)
            #expect(first.body["ruleText"] as? String == "Monthly on the 4th")
            #expect(first.body["note"] as? String == "22k")
            #expect(first.body["nextOn"] as? String == "2026-12-04")
            let retry = try await me.send(client, .post, "/v1/commitments", json: json)
            #expect(retry.status == .ok && retry.body["id"] as? String == json["id"] as? String)

            let bad: [([String: any Sendable], String)] = [
                (["kind": "weeklyOn"], "invalid_rule"),
                (["kind": "daily", "weekday": "monday"], "invalid_rule"),
                (["kind": "monthlyOnDay", "day": 32], "invalid_rule"),
                (["kind": "monthlyOnNthWeekday", "n": 6, "weekday": "saturday"], "invalid_rule"),
                (["kind": "quarterlyOnNthWeekday", "n": 1], "invalid_rule"),
            ]
            for (rule, expected) in bad {
                let r = try await me.send(
                    client, .post, "/v1/commitments", json: commitmentJSON(rule))
                #expect(r.status == .badRequest && code(r.body) == expected, "\(rule)")
            }
            let long = try await me.send(
                client, .post, "/v1/commitments", json: commitmentJSON(minutes: 1441))
            #expect(code(long.body) == "invalid_minutes")
            let window = try await me.send(
                client, .post, "/v1/commitments",
                json: commitmentJSON(extra: ["endOn": "2026-10-01"]))
            #expect(code(window.body) == "invalid_window")
            let badDay = try await me.send(
                client, .post, "/v1/commitments",
                json: commitmentJSON(extra: ["startOn": "2026-02-30"]))
            #expect(code(badDay.body) == "invalid_day")
            let goal = try await me.send(
                client, .post, "/v1/commitments",
                json: commitmentJSON(extra: ["goalId": newID().rawValue]))
            #expect(goal.status == .notFound)
        }
    }

    @Test func updateClearAndDelete() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            let made = try await me.send(
                client, .post, "/v1/commitments",
                json: commitmentJSON(extra: ["note": "x", "category": "learning"]))
            let id = made.body["id"] as! String
            let changed = try await me.send(
                client, .patch, "/v1/commitments/\(id)",
                json: [
                    "minutes": 30, "rule": ["kind": "weeklyOn", "weekday": "friday"],
                    "clear": ["note"],
                ] as [String: any Sendable])
            #expect(changed.status == .ok)
            #expect(changed.body["minutes"] as? Int == 30 && changed.body["note"] == nil)
            #expect(changed.body["ruleText"] as? String == "Every Friday")
            #expect(changed.body["category"] as? String == "learning")
            let both = try await me.send(
                client, .patch, "/v1/commitments/\(id)",
                json: ["note": "y", "clear": ["note"]] as [String: any Sendable])
            #expect(code(both.body) == "conflicting_clear")

            let deleted = try await me.send(client, .delete, "/v1/commitments/\(id)")
            #expect(deleted.status == .noContent)
            #expect(try await me.send(client, .get, "/v1/commitments/\(id)").status == .notFound)
            let list = try await me.send(client, .get, "/v1/commitments").body
            #expect((list["commitments"] as? [Any])?.isEmpty == true)
            // History stays, and the archived row ended today.
            let stored = try await me.store().commitment(ULID(id)!)
            #expect(
                stored?.archived == true && stored?.commitment.endOn?.description == "2026-11-23")
        }
    }

    @Test func otherUsersCommitmentIsNotFound() async throws {
        let me = Caller()
        let them = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            let made = try await them.send(client, .post, "/v1/commitments", json: commitmentJSON())
            let id = made.body["id"] as! String
            _ = try await me.send(client, .get, "/v1/me")
            #expect(try await me.send(client, .get, "/v1/commitments/\(id)").status == .notFound)
            #expect(
                try await me.send(client, .patch, "/v1/commitments/\(id)", json: ["minutes": 1])
                    .status == .notFound)
            #expect(
                try await me.send(
                    client, .put, "/v1/commitments/\(id)/occurrences/2026-11-23",
                    json: ["state": "done"]
                ).status == .notFound)
            #expect(try await me.send(client, .delete, "/v1/commitments/\(id)").status == .notFound)
        }
    }

    @Test func occurrencesDoneSkippedMovedAndStreak() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            let made = try await me.send(client, .post, "/v1/commitments", json: commitmentJSON())
            let id = made.body["id"] as! String
            func mark(_ day: String, _ json: [String: any Sendable]) async throws
                -> (status: HTTPResponse.Status, body: [String: Any])
            {
                try await me.send(
                    client, .put, "/v1/commitments/\(id)/occurrences/\(day)", json: json)
            }
            for day in ["2026-11-20", "2026-11-21", "2026-11-22"] {
                #expect(try await mark(day, ["state": "done"]).status == .ok)
            }
            let streak = try await me.send(client, .get, "/v1/commitments/\(id)").body["streak"]
            #expect(streak as? Int == 3)

            #expect(code(try await mark("2026-11-24", ["state": "done"]).body) == "in_future")
            #expect(code(try await mark("2026-11-24", ["state": "moved"]).body) == "invalid_move")
            #expect(
                code(
                    try await mark("2026-11-23", ["state": "skipped", "movedTo": "2026-11-24"]).body
                )
                    == "invalid_move")
            // A future day can be skipped (a planned day off).
            #expect(try await mark("2026-11-25", ["state": "skipped"]).status == .ok)

            // Today moved to tomorrow: no longer owed today.
            let moved = try await mark("2026-11-23", ["state": "moved", "movedTo": "2026-11-24"])
            #expect(moved.body["movedTo"] as? String == "2026-11-24")
            let plan = try await me.send(client, .get, "/v1/plan").body
            let today = (plan["commitments"] as! [[String: Any]])[0]
            #expect(
                today["state"] as? String == "moved" && today["movedTo"] as? String == "2026-11-24")
            #expect(plan["committedMinutes"] as? Int == 0)

            let week =
                try await me.send(
                    client, .get, "/v1/occurrences?from=2026-11-24&through=2026-11-26"
                ).body["occurrences"] as! [[String: Any]]
            // 24 (own), the 23rd moved in, 25 skipped, 26 (own).
            #expect(
                week.map { $0["day"] as? String } == [
                    "2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26",
                ])

            // Undo, then out of range.
            #expect(
                try await me.send(client, .delete, "/v1/commitments/\(id)/occurrences/2026-11-25")
                    .status == .noContent)
            let range = try await me.send(
                client, .get, "/v1/occurrences?from=2026-01-01&through=2026-12-31")
            #expect(code(range.body) == "invalid_range")
            let backwards = try await me.send(
                client, .get, "/v1/occurrences?from=2026-11-25&through=2026-11-24")
            #expect(code(backwards.body) == "invalid_range")
        }
    }

    @Test func aWeeklyCommitmentCannotBeMarkedOnAnotherDay() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            let made = try await me.send(
                client, .post, "/v1/commitments",
                json: commitmentJSON(["kind": "weeklyOn", "weekday": "friday"]))
            let id = made.body["id"] as! String
            let r = try await me.send(
                client, .put, "/v1/commitments/\(id)/occurrences/2026-11-23",
                json: ["state": "done"])
            #expect(code(r.body) == "not_scheduled")
            let friday = try await me.send(
                client, .put, "/v1/commitments/\(id)/occurrences/2026-11-20",
                json: ["state": "done"])
            #expect(friday.status == .ok)
        }
    }

    /// Decision 3: done on the day it was moved to counts for the original day.
    @Test func movedThenDoneCountsForTheOriginalDay() async throws {
        let me = Caller()
        let tuesday = mondayEarlyIST.addingTimeInterval(86_400)
        let clock = Clock(mondayEarlyIST)
        try await testApp(clock: { clock.now }).test(.router) { client in
            let made = try await me.send(client, .post, "/v1/commitments", json: commitmentJSON())
            let id = made.body["id"] as! String
            _ = try await me.send(
                client, .put, "/v1/commitments/\(id)/occurrences/2026-11-23",
                json: ["state": "moved", "movedTo": "2026-11-24"])
            // Not yet: the 24th has not come.
            let early = try await me.send(
                client, .put, "/v1/commitments/\(id)/occurrences/2026-11-23",
                json: ["state": "done"])
            #expect(code(early.body) == "in_future")

            clock.now = tuesday
            let plan = try await me.send(client, .get, "/v1/plan").body
            let rows = plan["commitments"] as! [[String: Any]]
            #expect(rows.contains { $0["movedFrom"] as? String == "2026-11-23" })
            #expect(plan["committedMinutes"] as? Int == 40)  // its own day and the moved one

            let done = try await me.send(
                client, .put, "/v1/commitments/\(id)/occurrences/2026-11-23",
                json: ["state": "done"])
            #expect(done.status == .ok && done.body["movedTo"] as? String == "2026-11-24")
            let after = try await me.send(client, .get, "/v1/plan").body
            #expect(after["committedMinutes"] as? Int == 20)
            let completed = try await me.store().completedDays(
                since: CalendarDay(year: 2026, month: 11, day: 1)!)
            #expect(completed[ULID(id)!] == [CalendarDay(year: 2026, month: 11, day: 23)!])
        }
    }

    @Test func reviewCountsWithoutStoringMisses() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            let made = try await me.send(
                client, .post, "/v1/commitments",
                json: commitmentJSON(extra: ["startOn": "2026-11-16"]))
            let id = made.body["id"] as! String
            for (day, state) in [
                ("2026-11-16", "done"), ("2026-11-17", "done"), ("2026-11-18", "skipped"),
                ("2026-11-20", "done"),
            ] {
                _ = try await me.send(
                    client, .put, "/v1/commitments/\(id)/occurrences/\(day)", json: ["state": state]
                )
            }
            let review = try await me.send(
                client, .get, "/v1/review?from=2026-11-16&through=2026-11-22")
            #expect(review.status == .ok)
            let c = (review.body["commitments"] as! [[String: Any]])[0]
            #expect(c["expected"] as? Int == 7 && c["done"] as? Int == 3)
            #expect(c["skipped"] as? Int == 1 && c["missed"] as? Int == 3)  // 19, 21, 22
            #expect(abs((c["hitRate"] as? Double ?? 0) - 3.0 / 7.0) < 1e-9)
            // Still nothing stored for a miss.
            let rows = try await me.store().occurrences(
                from: CalendarDay(year: 2026, month: 11, day: 16)!,
                through: CalendarDay(year: 2026, month: 11, day: 22)!)
            #expect(rows.count == 4)
        }
    }

    @Test func goalPeriodsAndRollups() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            func goal(_ title: String, _ extra: [String: any Sendable]) async throws
                -> (status: HTTPResponse.Status, body: [String: Any])
            {
                var json: [String: any Sendable] = ["id": newID().rawValue, "title": title]
                json.merge(extra) { $1 }
                return try await me.send(client, .post, "/v1/goals", json: json)
            }
            let q4 = try await goal("iOS contract job", ["period": "2026-Q4"])
            #expect(q4.body["periodText"] as? String == "Q4 2026")
            let q4id = q4.body["id"] as! String
            let nov = try await goal(
                "start job hunt flow", ["period": "2026-11", "parentId": q4id])
            #expect(nov.status == .created && nov.body["parentId"] as? String == q4id)

            // A month outside the quarter, a month as parent, a parent with no period.
            let jan = try await goal("x", ["period": "2027-01", "parentId": q4id])
            #expect(code(jan.body) == "invalid_rollup")
            let monthParent = try await goal(
                "y", ["period": "2026-11", "parentId": nov.body["id"] as! String])
            #expect(code(monthParent.body) == "invalid_rollup")
            #expect(code(try await goal("z", ["period": "2026-13"]).body) == "invalid_period")
            #expect(try await goal("z", ["parentId": newID().rawValue]).status == .notFound)

            // Moving the quarter would strand November.
            let strand = try await me.send(
                client, .patch, "/v1/goals/\(q4id)", json: ["period": "2027-Q1"])
            #expect(code(strand.body) == "invalid_rollup")

            let listed = try await me.send(client, .get, "/v1/goals?period=2026-11").body
            #expect(
                (listed["goals"] as? [[String: Any]])?.map { $0["title"] as? String } == [
                    "start job hunt flow"
                ])

            let review =
                try await me.send(
                    client, .get, "/v1/review?from=2026-11-01&through=2026-11-30"
                ).body["goals"] as! [[String: Any]]
            let quarter = review.first { ($0["goal"] as? [String: Any])?["id"] as? String == q4id }
            #expect((quarter?["children"] as? [[String: Any]])?.count == 1)

            // Clearing the parent frees the quarter to move.
            let freed = try await me.send(
                client, .patch, "/v1/goals/\(nov.body["id"] as! String)",
                json: ["clear": ["parentId"]])
            #expect(freed.status == .ok && freed.body["parentId"] == nil)
            #expect(
                try await me.send(client, .patch, "/v1/goals/\(q4id)", json: ["period": "2027-Q1"])
                    .status == .ok)
        }
    }

    /// D4: the swap is a correction; accepting is not.
    @Test func bigTaskSwapIsRecorded() async throws {
        let me = Caller()
        let proposed = Item(id: newID(), title: "send invoice", createdAt: mondayEarlyIST)
        let chosen = Item(id: newID(), title: "call bank", createdAt: mondayEarlyIST)
        let finished = Item(
            id: newID(), title: "old", status: .done, createdAt: mondayEarlyIST)
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            _ = try await me.send(client, .get, "/v1/me")
            for item in [proposed, chosen, finished] { try await me.store().insertItem(item) }
            let r = try await me.send(
                client, .put, "/v1/daily-plans/2026-11-23",
                json: ["itemId": chosen.id.rawValue, "proposedItemId": proposed.id.rawValue])
            #expect(r.status == .ok && r.body["swapped"] as? Bool == true)
            let corrections = try await me.store().corrections()
            #expect(corrections.map(\.field) == ["bigTask"])

            let plan = try await me.send(client, .get, "/v1/plan").body
            #expect((plan["bigTask"] as? [String: Any])?["itemId"] as? String == chosen.id.rawValue)

            let tooFar = try await me.send(
                client, .put, "/v1/daily-plans/2026-11-26", json: ["itemId": chosen.id.rawValue])
            #expect(code(tooFar.body) == "day_out_of_range")
            let notOpen = try await me.send(
                client, .put, "/v1/daily-plans/2026-11-24", json: ["itemId": finished.id.rawValue])
            #expect(code(notOpen.body) == "item_not_open")
            let missing = try await me.send(
                client, .put, "/v1/daily-plans/2026-11-24", json: ["itemId": newID().rawValue])
            #expect(missing.status == .notFound)

            let review = try await me.send(
                client, .get, "/v1/review?from=2026-11-23&through=2026-11-29")
            #expect(review.body["bigTasksConfirmed"] as? Int == 1)
            #expect(review.body["bigTasksSwapped"] as? Int == 1)
        }
    }

    @Test func journalOneEntryPerDay() async throws {
        let me = Caller()
        try await testApp(clock: { mondayEarlyIST }).test(.router) { client in
            let first = try await me.send(
                client, .put, "/v1/journal/2026-11-23", json: ["body": "good day"])
            #expect(first.status == .ok)
            _ = try await me.send(client, .put, "/v1/journal/2026-11-23", json: ["body": "better"])
            let future = try await me.send(
                client, .put, "/v1/journal/2026-11-24", json: ["body": "not yet"])
            #expect(code(future.body) == "in_future")
            let long = try await me.send(
                client, .put, "/v1/journal/2026-11-22",
                json: ["body": String(repeating: "a", count: 2001)])
            #expect(code(long.body) == "body_too_long")
            let list =
                try await me.send(
                    client, .get, "/v1/journal?from=2026-11-17&through=2026-11-23"
                ).body["entries"] as! [[String: Any]]
            #expect(list.map { $0["body"] as? String } == ["better"])
            #expect(
                try await me.send(client, .delete, "/v1/journal/2026-11-23").status == .noContent)
            // Journal entries are not items.
            #expect(try await me.store().items().isEmpty)
        }
    }

    @Test func plannerEnumsMatchBrain() {
        #expect(
            Set(CommitmentKind.allCases.map(\.rawValue))
                == Set(Components.Schemas.CommitmentKind.allCases.map(\.rawValue)))
        #expect(
            Set(OccurrenceState.allCases.map(\.rawValue))
                == Set(Components.Schemas.OccurrenceState.allCases.map(\.rawValue)))
        for w in BrainCore.Weekday.allCases {
            #expect(BrainCore.Weekday(Components.Schemas.Weekday(w)) == w)
        }
    }
}

/// A clock a test can move forward.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
