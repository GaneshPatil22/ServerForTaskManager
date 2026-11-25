import BrainCore
import Foundation
import PostgresNIO
import Testing

@testable import Storage

@Suite("Comments and count goals")
struct CommentStorageTests {
    func comment(on target: CommentTarget, _ body: String, at date: Date = fixedDate)
        -> StoredComment
    {
        StoredComment(id: newID(), target: target, body: body, createdAt: date, updatedAt: date)
    }

    @Test func commentsAttachToItemsGoalsAndCommitments() async throws {
        let store = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: store)
        let commitment = makeCommitment(.daily)
        _ = try await store.insertCommitment(commitment)

        let onItem = comment(on: .item(seed.item.id), "called, they said Monday")
        let later = comment(
            on: .item(seed.item.id), "Monday came", at: fixedDate.addingTimeInterval(60))
        let onGoal = comment(on: .goal(seed.goal.id), "this quarter only")
        let onCommitment = comment(on: .commitment(commitment.commitment.id), "skipped: travel")
        for c in [later, onItem, onGoal, onCommitment] {
            #expect(try await store.insertComment(c).created)
        }
        // Oldest first, and each thing sees only its own.
        #expect(try await store.comments(on: .item(seed.item.id)) == [onItem, later])
        #expect(try await store.comments(on: .goal(seed.goal.id)) == [onGoal])
        #expect(
            try await store.comments(on: .commitment(commitment.commitment.id)) == [onCommitment])
        // A retry returns what is stored.
        #expect(try await !store.insertComment(onItem).created)
    }

    @Test func editAndDelete() async throws {
        let store = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: store)
        let c = comment(on: .item(seed.item.id), "first")
        _ = try await store.insertComment(c)
        let later = fixedDate.addingTimeInterval(30)
        let edited = try #require(try await store.editComment(c.id, body: "second", at: later))
        #expect(edited.body == "second" && edited.updatedAt == later)
        #expect(edited.createdAt == c.createdAt)
        #expect(try await store.deleteComment(c.id))
        #expect(try await !store.deleteComment(c.id))
        #expect(try await store.editComment(c.id, body: "x", at: later) == nil)
    }

    /// The database holds "exactly one thing, and it exists".
    @Test func aCommentAlwaysPointsAtOneRealThing() async throws {
        let mine = try await TestDatabase.newUser()
        let theirs = try await TestDatabase.newUser()
        let theirSeed = try await Seed.insert(into: theirs)
        await #expect(throws: CountRefusal.unknownTarget) {
            _ = try await mine.insertComment(comment(on: .item(theirSeed.item.id), "hi"))
        }
        await #expect(throws: CountRefusal.unknownTarget) {
            _ = try await mine.insertComment(comment(on: .goal(newID()), "hi"))
        }
        let seed = try await Seed.insert(into: mine)
        await expectSQLState("23514") {
            try await mine.client.query(
                """
                INSERT INTO comments (user_id, id, item_id, goal_id, body, created_at, updated_at)
                VALUES (\(mine.user.rawValue), \(newID().rawValue), \(seed.item.id.rawValue),
                        \(seed.goal.id.rawValue), 'both', now(), now())
                """, logger: mine.logger)
        }
        // And another user's comments are invisible and untouchable.
        let theirComment = comment(on: .item(theirSeed.item.id), "theirs")
        _ = try await theirs.insertComment(theirComment)
        #expect(try await mine.comment(theirComment.id) == nil)
        #expect(try await mine.editComment(theirComment.id, body: "x", at: fixedDate) == nil)
        #expect(try await !mine.deleteComment(theirComment.id))
    }

    @Test func countGoalFillsUpToItsTarget() async throws {
        let store = try await TestDatabase.newUser()
        let goal = Goal(id: newID(), title: "Finish 6 big books", createdAt: fixedDate)
        _ = try await store.insertGoal(goal, targetCount: 2)
        func mark(_ d: Int, _ note: String? = nil) -> GoalMark {
            GoalMark(
                id: newID(), goalId: goal.id, day: day(2026, 11, d), note: note,
                createdAt: fixedDate, updatedAt: fixedDate)
        }
        let first = mark(20, "Atomic Habits")
        #expect(try await store.addMark(first).created)
        #expect(try await !store.addMark(first).created, "a retry fills nothing more")
        _ = try await store.addMark(mark(22))
        await #expect(throws: CountRefusal.targetReached) {
            _ = try await store.addMark(mark(23))
        }
        #expect(try await store.goalCounts()[goal.id] == GoalCount(target: 2, done: 2))
        // Nothing about the goal itself changed: filling is not achieving.
        #expect(try await store.goal(goal.id)?.status == .active)

        // The target cannot drop below what is filled, nor be removed.
        await #expect(throws: CountRefusal.targetBelowDone(done: 2)) {
            try await store.setGoalTarget(goal.id, to: 1)
        }
        await #expect(throws: CountRefusal.targetBelowDone(done: 2)) {
            try await store.setGoalTarget(goal.id, to: nil)
        }
        #expect(try await store.setGoalTarget(goal.id, to: 6))

        let edited = try await store.editMark(
            first.id, goal: goal.id, note: "Atomic Habits, notes done", at: fixedDate)
        #expect(edited?.note == "Atomic Habits, notes done")
        #expect(try await store.deleteMark(first.id, goal: goal.id))
        #expect(try await store.marks(of: goal.id).map(\.day) == [day(2026, 11, 22)])
    }

    @Test func anOrdinaryGoalHasNoCircles() async throws {
        let store = try await TestDatabase.newUser()
        let goal = Goal(id: newID(), title: "Find a new iOS contract job", createdAt: fixedDate)
        _ = try await store.insertGoal(goal)
        #expect(try await store.goalCounts()[goal.id] == nil)
        await #expect(throws: CountRefusal.notACountGoal) {
            _ = try await store.addMark(
                GoalMark(
                    id: newID(), goalId: goal.id, day: day(2026, 11, 20), note: nil,
                    createdAt: fixedDate, updatedAt: fixedDate))
        }
        await expectSQLState("23514") {
            try await store.setGoalTarget(goal.id, to: 1001)
        }
    }

    @Test func anotherUsersGoalCannotBeCounted() async throws {
        let mine = try await TestDatabase.newUser()
        let theirs = try await TestDatabase.newUser()
        let goal = Goal(id: newID(), title: "theirs", createdAt: fixedDate)
        _ = try await theirs.insertGoal(goal, targetCount: 3)
        await #expect(throws: CountRefusal.unknownTarget) {
            _ = try await mine.addMark(
                GoalMark(
                    id: newID(), goalId: goal.id, day: day(2026, 11, 20), note: nil,
                    createdAt: fixedDate, updatedAt: fixedDate))
        }
        #expect(try await !mine.setGoalTarget(goal.id, to: 5))
        #expect(try await mine.goalCounts().isEmpty)
        #expect(try await theirs.goalCounts()[goal.id] == GoalCount(target: 3, done: 0))
    }
}
