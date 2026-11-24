import BrainCore
import Foundation
import PostgresNIO
import Testing

@testable import Storage

func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay { CalendarDay(year: y, month: m, day: d)! }

func makeCommitment(
    _ rule: RecurrenceRule, kind: CommitmentKind = .habit, goal: ULID? = nil,
    start: CalendarDay = day(2026, 11, 1), note: String? = nil
) -> StoredCommitment {
    StoredCommitment(
        commitment: Commitment(
            id: newID(), title: "read 10 pages", kind: kind, rule: rule, minutes: 20,
            category: .learning, goalId: goal, startOn: start, note: note),
        createdAt: fixedDate, updatedAt: fixedDate)
}

@Suite("Planner storage")
struct PlannerStorageTests {
    @Test func everyRuleShapeRoundTrips() async throws {
        let store = try await TestDatabase.newUser()
        let goal = Goal(id: newID(), title: "learn", createdAt: fixedDate)
        try await store.insertGoal(goal)
        let rules: [RecurrenceRule] = [
            .daily, .weeklyOn(.friday), .monthlyOnDay(31),
            .monthlyOnNthWeekday(n: 1, weekday: .saturday),
            .quarterlyOnNthWeekday(n: 5, weekday: .sunday),
        ]
        var stored: [StoredCommitment] = []
        for rule in rules {
            var c = makeCommitment(rule, goal: goal.id, note: "22k")
            c.commitment.endOn = day(2027, 3, 31)
            #expect(try await store.insertCommitment(c).created)
            stored.append(c)
        }
        #expect(try await store.commitments() == stored)
        // A retry returns what is stored.
        let retry = try await store.insertCommitment(stored[0])
        #expect(!retry.created && retry.commitment == stored[0])
    }

    /// Brain accepts any `Int`; the database is what refuses nonsense.
    @Test func databaseRefusesImpossibleRules() async throws {
        let store = try await TestDatabase.newUser()
        await expectSQLState("23514") {
            _ = try await store.insertCommitment(makeCommitment(.monthlyOnDay(32)))
        }
        await expectSQLState("23514") {
            _ = try await store.insertCommitment(
                makeCommitment(.monthlyOnNthWeekday(n: 6, weekday: .monday)))
        }
        var long = makeCommitment(.daily)
        long.commitment.minutes = 1441
        await expectSQLState("23514") { _ = try await store.insertCommitment(long) }
    }

    @Test func archivedCommitmentsAreHiddenButKept() async throws {
        let store = try await TestDatabase.newUser()
        var c = makeCommitment(.daily)
        _ = try await store.insertCommitment(c)
        c.archived = true
        #expect(try await store.replaceCommitment(c))
        #expect(try await store.commitments().isEmpty)
        #expect(try await store.commitments(includeArchived: true) == [c])
    }

    @Test func anotherUsersCommitmentAndGoalAreUnreachable() async throws {
        let mine = try await TestDatabase.newUser()
        let theirs = try await TestDatabase.newUser()
        let goal = Goal(id: newID(), title: "theirs", createdAt: fixedDate)
        try await theirs.insertGoal(goal)
        let c = makeCommitment(.daily)
        _ = try await theirs.insertCommitment(c)

        await #expect(throws: PlannerRefusal.unknownReference) {
            _ = try await mine.insertCommitment(makeCommitment(.daily, goal: goal.id))
        }
        await #expect(throws: PlannerRefusal.unknownReference) {
            _ = try await mine.setOccurrence(
                c.commitment.id, day: day(2026, 11, 2), state: .done, movedTo: nil, at: fixedDate)
        }
        #expect(try await mine.commitment(c.commitment.id) == nil)
        #expect(try await !mine.replaceCommitment(c))
    }

    @Test func occurrencesCarryOnlyState() async throws {
        let store = try await TestDatabase.newUser()
        let c = makeCommitment(.daily)
        let id = c.commitment.id
        _ = try await store.insertCommitment(c)

        _ = try await store.setOccurrence(
            id, day: day(2026, 11, 2), state: .done, movedTo: nil, at: fixedDate)
        _ = try await store.setOccurrence(
            id, day: day(2026, 11, 3), state: .skipped, movedTo: nil, at: fixedDate)
        _ = try await store.setOccurrence(
            id, day: day(2026, 11, 4), state: .moved, movedTo: day(2026, 11, 10), at: fixedDate)

        // A week that holds none of the days but receives the moved one.
        let moved = try await store.occurrences(from: day(2026, 11, 9), through: day(2026, 11, 15))
        #expect(moved.map(\.day) == [day(2026, 11, 4)])

        // Changing state replaces; clearing removes the row.
        _ = try await store.setOccurrence(
            id, day: day(2026, 11, 3), state: .done, movedTo: nil, at: fixedDate)
        #expect(try await store.clearOccurrence(id, day: day(2026, 11, 2)))
        #expect(try await !store.clearOccurrence(id, day: day(2026, 11, 2)))

        let done = try await store.completedDays(since: day(2026, 11, 1))
        #expect(done == [id: [day(2026, 11, 3)]])
        // Nothing stored for a missed day, so nothing to read back (D2).
        let all = try await store.occurrences(from: day(2026, 11, 1), through: day(2026, 11, 30))
        #expect(all.count == 2)
    }

    @Test func movedNeedsATargetAndSkipCannotHaveOne() async throws {
        let store = try await TestDatabase.newUser()
        let c = makeCommitment(.daily)
        _ = try await store.insertCommitment(c)
        await expectSQLState("23514") {
            _ = try await store.setOccurrence(
                c.commitment.id, day: day(2026, 11, 2), state: .moved, movedTo: nil,
                at: fixedDate)
        }
        await expectSQLState("23514") {
            _ = try await store.setOccurrence(
                c.commitment.id, day: day(2026, 11, 2), state: .skipped,
                movedTo: day(2026, 11, 3), at: fixedDate)
        }
    }

    @Test func journalIsOneEntryPerDay() async throws {
        let store = try await TestDatabase.newUser()
        let first = try await store.writeJournal(day: day(2026, 11, 24), body: "one", at: fixedDate)
        let later = fixedDate.addingTimeInterval(60)
        let second = try await store.writeJournal(day: day(2026, 11, 24), body: "two", at: later)
        #expect(second.body == "two" && second.createdAt == first.createdAt)
        #expect(second.updatedAt == later)
        _ = try await store.writeJournal(day: day(2026, 11, 25), body: "three", at: fixedDate)
        let week = try await store.journal(from: day(2026, 11, 23), through: day(2026, 11, 29))
        #expect(week.map(\.body) == ["two", "three"])
        #expect(try await store.deleteJournal(day: day(2026, 11, 24)))
        #expect(
            try await store.journal(from: day(2026, 11, 24), through: day(2026, 11, 24)).isEmpty)
    }

    @Test func goalPeriodAndParentRoundTrip() async throws {
        let store = try await TestDatabase.newUser()
        let quarter = Goal(
            id: newID(), title: "iOS contract job", createdAt: fixedDate,
            period: GoalPeriod(horizon: .quarter, year: 2026, index: 4))
        let month = Goal(
            id: newID(), title: "start the job hunt flow", createdAt: fixedDate,
            period: GoalPeriod(horizon: .month, year: 2026, index: 11), parentId: quarter.id)
        try await store.insertGoal(quarter)
        try await store.insertGoal(month)
        #expect(try await store.goal(month.id) == month)
        #expect(try await store.goals(in: GoalPeriod(storedValue: "2026-Q4")!) == [quarter])

        var changed = month
        changed.parentId = nil
        changed.period = nil
        #expect(try await store.replaceGoal(changed))
        #expect(try await store.goal(month.id) == changed)
    }

    @Test func storedValuesParse() {
        #expect(CalendarDay(storedValue: "2026-11-24") == day(2026, 11, 24))
        #expect(CalendarDay(storedValue: "2026-02-30") == nil)
        #expect(CalendarDay(storedValue: "2026-1-24") == nil)
        #expect(GoalPeriod(storedValue: "2026-Q4")?.description == "2026-Q4")
        #expect(GoalPeriod(storedValue: "2026-11")?.description == "2026-11")
        for bad in ["2026-Q5", "2026-13", "2026-1", "26-11", "2026-Q", "2026-+1"] {
            #expect(GoalPeriod(storedValue: bad) == nil, "\(bad)")
        }
    }

    /// D4: a swap is a correction, recorded once per change of choice.
    @Test func bigTaskSwapIsACorrectionOnce() async throws {
        let store = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: store)
        let before = try await store.corrections().count
        let today = day(2026, 11, 24)

        // Accepting Brain's pick records nothing.
        let accepted = try await store.confirmDailyPlan(
            day: today, itemId: seed.item.id, proposedItemId: seed.item.id, at: fixedDate,
            correction: newID())
        #expect(!accepted.swapped)
        #expect(try await store.corrections().count == before)

        // Swapping records one; repeating the same call records nothing more.
        for _ in 0..<2 {
            let swapped = try await store.confirmDailyPlan(
                day: today, itemId: seed.other.id, proposedItemId: seed.item.id, at: fixedDate,
                correction: newID())
            #expect(swapped.swapped)
        }
        let corrections = try await store.corrections()
        #expect(corrections.count == before + 1)
        let swap = try #require(corrections.last)
        #expect(swap.field == "bigTask" && swap.tier == .t0)
        #expect(swap.beforeValue == seed.item.id.rawValue)
        #expect(swap.afterValue == seed.other.id.rawValue)
        #expect(try await store.dailyPlans(from: today, through: today).first?.swapped == true)
    }

    @Test func bigTaskMustBeTheUsersItem() async throws {
        let mine = try await TestDatabase.newUser()
        let theirs = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: theirs)
        await #expect(throws: PlannerRefusal.unknownReference) {
            _ = try await mine.confirmDailyPlan(
                day: day(2026, 11, 24), itemId: seed.item.id, proposedItemId: nil,
                at: fixedDate, correction: newID())
        }
    }
}

@Suite("Every table")
struct CatalogTests {
    /// Holds for tables added later, too: RLS on (the Supabase data API sees
    /// nothing) and a `user_id` to scope by. `users` is keyed by `id` itself;
    /// budget counters hold counts keyed by Brain's requester id, and the
    /// migrations table belongs to no user.
    @Test func everyPublicTableHasRLSAndAUserColumn() async throws {
        let db = try await TestDatabase.get()
        let rows = try await db.client.query(
            """
            SELECT c.relname, c.relrowsecurity,
                   EXISTS (SELECT 1 FROM pg_attribute a
                           WHERE a.attrelid = c.oid AND a.attname = 'user_id' AND NOT a.attisdropped)
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind = 'r'
            ORDER BY c.relname
            """, logger: db.logger)
        var seen: [String] = []
        for try await (name, rls, hasUser) in rows.decode((String, Bool, Bool).self) {
            seen.append(name)
            #expect(rls, "\(name) has RLS off")
            if !["users", "budget_model_daily", "budget_user_daily", "_hb_pg_migrations"].contains(
                name)
            {
                #expect(hasUser, "\(name) has no user_id")
            }
        }
        #expect(seen.contains("commitments") && seen.contains("daily_plans"))
    }
}
