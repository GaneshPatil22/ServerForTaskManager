import BrainCore
import Foundation
import Jobs
import JobsPostgres
import Logging
import ServiceLifecycle
import Storage

/// What the API needs: "this capture exists, please enrich it".
public protocol EnrichmentEnqueuing: Sendable {
    func enqueue(user: UserID, capture: ULID) async
}

/// The swift-jobs queue (Postgres-backed) with both jobs registered, and the
/// sweeper scheduled every minute.
///
/// **A capture is safe before it is queued.** It is committed first; the
/// push comes after and can fail. A lost push only delays enrichment: the
/// sweeper finds every capture that is `raw` past its grace period, stuck in
/// `enriching`, or `failed` without an item, and queues it again. Duplicate
/// jobs are harmless because `claimCapture` lets exactly one of them work.
public struct EnrichmentQueue: EnrichmentEnqueuing {
    let queue: JobQueue<PostgresJobQueue>
    let logger: Logger

    public static func make(
        database: Database, enricher: Enricher, settings: EnrichmentSettings = .init(),
        logger: Logger
    ) async -> EnrichmentQueue {
        let queue = JobQueue(await database.makeJobQueueDriver(), logger: logger)

        queue.registerJob(
            parameters: EnrichCapture.self,
            retryStrategy: .exponentialJitter(maxAttempts: 4, maxBackoff: .seconds(60))
        ) { job, _ in
            guard let capture = ULID(job.capture) else {
                logger.error("enrich job with a malformed capture id, dropped")
                return
            }
            _ = try await enricher.enrich(user: UserID(job.user), capture: capture)
        }

        queue.registerJob(parameters: SweepCaptures.self, retryStrategy: .dontRetry) { _, _ in
            let due = try await database.capturesNeedingEnrichment(
                now: Date(), rawGrace: settings.rawGrace, stuckAfter: settings.stuckAfter,
                maxAttempts: settings.maxAttempts, limit: settings.sweepBatch)
            if !due.isEmpty {
                logger.info("sweeper requeueing captures", metadata: ["count": "\(due.count)"])
            }
            for (user, capture) in due {
                try await queue.push(EnrichCapture(user: user.rawValue, capture: capture.rawValue))
            }
        }
        return EnrichmentQueue(queue: queue, logger: logger)
    }

    public func enqueue(user: UserID, capture: ULID) async {
        do {
            try await queue.push(EnrichCapture(user: user.rawValue, capture: capture.rawValue))
        } catch {
            // Not lost: the capture is stored, and the sweeper will queue it.
            logger.error(
                "could not queue enrichment; the sweeper will", metadata: ["error": "\(error)"])
        }
    }

    /// The worker and the sweeper's schedule, to run after migrations.
    public func services(workers: Int) async -> [any Service] {
        var schedule = JobSchedule()
        schedule.addJob(SweepCaptures(), schedule: .everyMinute())
        return [
            queue.processor(options: .init(numWorkers: workers)),
            await schedule.scheduler(on: queue, named: "sweeper"),
        ]
    }
}
