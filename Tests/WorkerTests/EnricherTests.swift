import BrainCore
import Foundation
import Logging
import Storage
import TestDatabase
import Testing

@testable import Worker

let now = Date(timeIntervalSince1970: 1_795_000_000)

/// Rules only (T0): deterministic, no model, no key. Brain tests the model path.
func enricher(clock: @escaping @Sendable () -> Date = { now }) async throws -> Enricher {
    Enricher(
        database: try await TestDatabase.get(), router: nil,
        logger: Logger(label: "worker-tests"), clock: clock)
}

func storedCapture(_ text: String, in store: UserStore, at date: Date = now) async throws
    -> Capture
{
    let capture = Capture(id: newID(), rawText: text, createdAt: date)
    _ = try await store.insertCapture(capture)
    return capture
}

@Suite("Enricher")
struct EnricherTests {
    @Test func rawCaptureBecomesAnEnrichedItem() async throws {
        let store = try await TestDatabase.newUser()
        let capture = try await storedCapture("call the bank tomorrow about the loan", in: store)

        let outcome = try await enricher().enrich(user: store.user, capture: capture.id)
        guard case .enriched(let itemID, _) = outcome else {
            Issue.record("expected enriched, got \(outcome)")
            return
        }
        let item = try #require(try await store.item(itemID))
        #expect(item.captureId == capture.id)
        #expect(item.dueAt.value != nil, "T0 parses 'tomorrow'")
        #expect(item.dueAt.tier == .t0)
        let stored = try #require(try await store.capture(capture.id))
        #expect(stored.status == .enriched)
        #expect(stored.rawText == capture.rawText, "the capture itself is never changed")
    }

    @Test func runningTwiceMakesOneItem() async throws {
        let store = try await TestDatabase.newUser()
        let capture = try await storedCapture("buy milk", in: store)
        let worker = try await enricher()
        _ = try await worker.enrich(user: store.user, capture: capture.id)
        let again = try await worker.enrich(user: store.user, capture: capture.id)
        #expect(again == .nothingToDo)
        #expect(try await store.items().count == 1)
    }

    /// Duplicate jobs (the sweeper requeued it while the first was queued)
    /// must still produce exactly one item.
    @Test func concurrentJobsForOneCaptureMakeOneItem() async throws {
        let store = try await TestDatabase.newUser()
        let capture = try await storedCapture("renew passport", in: store)
        let worker = try await enricher()
        let outcomes = try await withThrowingTaskGroup(of: Enricher.Outcome.self) { group in
            for _ in 0..<8 {
                group.addTask { try await worker.enrich(user: store.user, capture: capture.id) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.filter { $0 != .nothingToDo }.count == 1)
        #expect(try await store.items().count == 1)
    }

    @Test func statedDependencyBecomesAnUnconfirmedLink() async throws {
        let store = try await TestDatabase.newUser()
        let blocker = Item(id: newID(), title: "Get client approval", createdAt: now)
        try await store.insertItem(blocker)
        let capture = try await storedCapture("client approval ke baad invoice bhejna h", in: store)

        let outcome = try await enricher().enrich(user: store.user, capture: capture.id)
        guard case .enriched(let itemID, let edgeCount) = outcome else {
            Issue.record("expected enriched, got \(outcome)")
            return
        }
        #expect(edgeCount == 1)
        let edge = try #require(try await store.edges().first)
        #expect(edge.from == blocker.id)
        #expect(edge.to == itemID)
        #expect(edge.kind == .blocks)
        #expect(edge.confirmed == false, "invariant 3: only the user confirms")
        #expect(edge.source == .t0Rule)
    }

    @Test func anotherUsersCaptureIsInvisibleToTheWorker() async throws {
        let alice = try await TestDatabase.newUser()
        let bob = try await TestDatabase.newUser()
        let capture = try await storedCapture("alice's thing", in: alice)
        // A job naming Bob with Alice's capture id must find nothing.
        #expect(try await enricher().enrich(user: bob.user, capture: capture.id) == .nothingToDo)
        #expect(try await alice.capture(capture.id)?.status == .raw)
        #expect(try await bob.items().isEmpty)
    }

    @Test func linksAreMadeOnlyWithinTheUsersOwnItems() async throws {
        let alice = try await TestDatabase.newUser()
        let bob = try await TestDatabase.newUser()
        try await alice.insertItem(Item(id: newID(), title: "Get client approval", createdAt: now))
        let capture = try await storedCapture("client approval ke baad invoice bhejna h", in: bob)
        let outcome = try await enricher().enrich(user: bob.user, capture: capture.id)
        #expect(outcome != .nothingToDo)
        #expect(try await bob.edges().isEmpty, "Bob's capture can't link to Alice's item")
    }
}

@Suite("Sweeper selection")
struct SweeperTests {
    func due(after seconds: TimeInterval) async throws -> Set<ULID> {
        let settings = EnrichmentSettings()
        let found = try await TestDatabase.get().capturesNeedingEnrichment(
            now: Date().addingTimeInterval(seconds), rawGrace: settings.rawGrace,
            stuckAfter: settings.stuckAfter, maxAttempts: settings.maxAttempts, limit: 10_000)
        return Set(found.map(\.capture))
    }

    @Test func picksLostRawCapturesButNotFreshOnes() async throws {
        let store = try await TestDatabase.newUser()
        let capture = try await storedCapture("lost job", in: store)
        #expect(!(try await due(after: 0)).contains(capture.id), "still inside its grace period")
        #expect(try await due(after: 121).contains(capture.id))
    }

    @Test func picksStuckButNotActiveWork() async throws {
        let store = try await TestDatabase.newUser()
        let capture = try await storedCapture("worker died", in: store)
        _ = try await store.claimCapture(capture.id, now: Date(), stuckAfter: 600)
        #expect(!(try await due(after: 60)).contains(capture.id), "a worker is on it")
        #expect(try await due(after: 601).contains(capture.id))
    }

    @Test func skipsCapturesThatAlreadyHaveAnItem() async throws {
        let store = try await TestDatabase.newUser()
        let capture = try await storedCapture("done", in: store)
        _ = try await enricher(clock: { Date() }).enrich(user: store.user, capture: capture.id)
        try await store.setCaptureStatus(capture.id, .failed)  // even if marked failed
        #expect(!(try await due(after: 10_000)).contains(capture.id))
    }

    @Test func stopsAfterMaxAttemptsButKeepsTheCapture() async throws {
        let store = try await TestDatabase.newUser()
        let capture = try await storedCapture("always fails", in: store)
        for _ in 0..<EnrichmentSettings().maxAttempts {
            _ = try await store.claimCapture(capture.id, now: Date(), stuckAfter: 600)
            try await store.setCaptureStatus(capture.id, .failed)
        }
        #expect(!(try await due(after: 10_000)).contains(capture.id))
        #expect(try await store.capture(capture.id) != nil, "never deleted")
    }
}
