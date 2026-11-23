import BrainCore
import Foundation
import Logging
import Storage
import TestDatabase
import Testing

@testable import Worker

/// The real swift-jobs queue on Postgres, end to end: push, a worker picks it
/// up, the capture ends up enriched.
@Suite("Postgres job queue", .serialized)
struct QueueTests {
    @Test func pushedCaptureGetsEnrichedByTheWorker() async throws {
        let database = try await TestDatabase.get()
        let logger = Logger(label: "queue-tests")
        let queue = await EnrichmentQueue.make(
            database: database, enricher: try await enricher(clock: { Date() }), logger: logger)
        try await database.migrate()  // the queue's own tables

        let store = try await TestDatabase.newUser()
        let capture = try await storedCapture("pay electricity bill friday", in: store)
        await queue.enqueue(user: store.user, capture: capture.id)

        let worker = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for service in await queue.services(workers: 2) {
                    group.addTask { try await service.run() }
                }
                try await group.waitForAll()
            }
        }
        defer { worker.cancel() }

        var status: CaptureStatus? = .raw
        for _ in 0..<100 where status != .enriched {
            try await Task.sleep(for: .milliseconds(100))
            status = try await store.capture(capture.id)?.status
        }
        #expect(status == .enriched)
        #expect(try await store.items().count == 1)
    }
}
