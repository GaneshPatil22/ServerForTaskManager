import BrainCore
import Foundation
import PostgresNIO
import Testing

@testable import Storage

/// A capture enriched into an item whose type no tier could read, stored
/// with Brain's question about it.
func askedAboutType(in store: UserStore, text: String = "the garden thing")
    async throws -> (item: Item, question: StoredQuestion)
{
    let capture = Capture(id: newID(), rawText: text, createdAt: fixedDate)
    _ = try await store.insertCapture(capture)
    let item = Item(id: newID(), captureId: capture.id, title: text, createdAt: fixedDate)
    let question = StoredQuestion(
        id: newID(), captureId: capture.id, itemId: item.id, field: "type",
        prompt: "What is “\(text)”?", options: ["task", "idea", "note", "reminder", "link"],
        createdAt: fixedDate)
    #expect(
        try await store.saveEnrichment(
            capture: capture.id, status: .enriched, item: item, edges: [],
            questions: [question]))
    return (item, question)
}

@Suite("Question storage")
struct QuestionStorageTests {
    @Test func questionIsStoredWithItsItemAndListedNewestFirst() async throws {
        let store = try await TestDatabase.newUser()
        let first = try await askedAboutType(in: store, text: "one")
        let capture = Capture(id: newID(), rawText: "two", createdAt: fixedDate)
        _ = try await store.insertCapture(capture)
        let item = Item(id: newID(), captureId: capture.id, title: "two", createdAt: fixedDate)
        var later = first.question
        later.id = newID()
        later.captureId = capture.id
        later.itemId = item.id
        later.createdAt = fixedDate.addingTimeInterval(60)
        _ = try await store.saveEnrichment(
            capture: capture.id, status: .enriched, item: item, edges: [], questions: [later])
        #expect(try await store.openQuestions() == [later, first.question])
    }

    /// The question is part of the enrichment: no item, no question.
    @Test func aQuestionNeverOutlivesItsItem() async throws {
        let store = try await TestDatabase.newUser()
        let asked = try await askedAboutType(in: store)
        // A second enrichment of the same capture writes nothing at all.
        let item = Item(
            id: newID(), captureId: asked.item.captureId, title: "again", createdAt: fixedDate)
        var again = asked.question
        again.id = newID()
        again.itemId = item.id
        #expect(
            try await !store.saveEnrichment(
                capture: asked.item.captureId!, status: .enriched, item: item, edges: [],
                questions: [again]))
        #expect(try await store.openQuestions() == [asked.question])

        // And the database refuses one that points at no item.
        var orphan = asked.question
        orphan.id = newID()
        orphan.itemId = newID()
        await expectSQLState("23503") {
            try await store.insertQuestion(orphan, on: store.client)
        }
    }

    @Test func databaseHoldsTheClosedSet() async throws {
        let store = try await TestDatabase.newUser()
        let asked = try await askedAboutType(in: store)
        await expectSQLState("23514") {
            try await store.client.query(
                """
                UPDATE questions SET answer = 'banana', answered_at = now()
                WHERE id = \(asked.question.id.rawValue)
                """, logger: store.logger)
        }
        var unknownField = asked.question
        unknownField.id = newID()
        unknownField.field = "effort"
        await expectSQLState("23514") {
            try await store.insertQuestion(unknownField, on: store.client)
        }
    }

    /// The answer sets the field as the user's, writes one `t3` correction,
    /// and takes the question off the list.
    @Test func answerAppliesAndBecomesACorrection() async throws {
        let store = try await TestDatabase.newUser()
        let asked = try await askedAboutType(in: store)
        let later = fixedDate.addingTimeInterval(120)

        let answered = try #require(
            try await store.answerQuestion(
                asked.question.id, option: "idea", at: later, correction: newID()))
        #expect(answered.answer == "idea" && answered.answeredAt == later)

        let item = try #require(try await store.item(asked.item.id))
        #expect(item.type.value == .idea && item.type.tier == .user)
        #expect(item.type.confidence == 1)
        let corrections = try await store.corrections()
        #expect(corrections.count == 1)
        let label = try #require(corrections.first)
        #expect(label.field == "type" && label.tier == .t3)
        #expect(label.beforeValue == nil && label.afterValue == "idea")
        #expect(label.targetId == asked.item.id)
        #expect(try await store.openQuestions().isEmpty)
    }

    @Test func answeringTwiceIsOneCorrection() async throws {
        let store = try await TestDatabase.newUser()
        let asked = try await askedAboutType(in: store)
        for _ in 0..<2 {
            _ = try await store.answerQuestion(
                asked.question.id, option: "task", at: fixedDate, correction: newID())
        }
        #expect(try await store.corrections().count == 1)
        await #expect(throws: QuestionRefusal.alreadyAnswered) {
            _ = try await store.answerQuestion(
                asked.question.id, option: "note", at: fixedDate, correction: newID())
        }
        #expect(try await store.item(asked.item.id)?.type.value == .task)
        #expect(try await store.corrections().count == 1)
    }

    @Test func anAnswerOutsideTheOptionsChangesNothing() async throws {
        let store = try await TestDatabase.newUser()
        let asked = try await askedAboutType(in: store)
        await #expect(throws: QuestionRefusal.notAnOption) {
            _ = try await store.answerQuestion(
                asked.question.id, option: "Task", at: fixedDate, correction: newID())
        }
        #expect(try await store.item(asked.item.id)?.type.value == nil)
        #expect(try await store.corrections().isEmpty)
        #expect(try await store.openQuestions() == [asked.question])
    }

    /// Setting the type by hand answers the question; the edit's own
    /// correction is the only one.
    @Test func editingTheTypeClosesTheQuestion() async throws {
        let store = try await TestDatabase.newUser()
        let asked = try await askedAboutType(in: store)
        _ = try await store.editItem(
            asked.item.id, UserStore.ItemChange(type: .reminder), at: fixedDate,
            newID: { newID() })
        #expect(try await store.openQuestions().isEmpty)
        #expect(try await store.question(asked.question.id)?.answer == "reminder")
        #expect(try await store.corrections().count == 1)
        // Answering it afterwards with the same value is a no-op.
        _ = try await store.answerQuestion(
            asked.question.id, option: "reminder", at: fixedDate, correction: newID())
        #expect(try await store.corrections().count == 1)
    }

    @Test func anotherUsersQuestionIsUnreachable() async throws {
        let mine = try await TestDatabase.newUser()
        let theirs = try await TestDatabase.newUser()
        let asked = try await askedAboutType(in: theirs)
        #expect(try await mine.openQuestions().isEmpty)
        #expect(try await mine.question(asked.question.id) == nil)
        #expect(
            try await mine.answerQuestion(
                asked.question.id, option: "task", at: fixedDate, correction: newID()) == nil)
        #expect(try await theirs.item(asked.item.id)?.type.value == nil)
    }
}
