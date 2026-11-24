import BrainCore
import BrainHarness
import BrainPipeline
import BrainProduction
import Foundation
import Logging
import Storage

public struct EnrichmentSettings: Sendable {
    /// A capture `enriching` for longer than this is assumed abandoned.
    public var stuckAfter: TimeInterval = 600
    /// A `raw` capture older than this has lost its job; the sweeper requeues it.
    public var rawGrace: TimeInterval = 120
    /// After this many attempts a capture is left alone. It is still kept.
    public var maxAttempts = 5
    public var sweepBatch = 200

    public init() {}
}

/// Enriches one capture end to end: claim it, run Brain's pipeline on the
/// user's graph, check every suggested link against Brain's graph rules, and
/// store the result atomically. Knows nothing about the job queue, so tests
/// call it directly.
public struct Enricher: Sendable {
    public enum Outcome: Equatable, Sendable {
        case enriched(item: ULID, edges: Int)
        /// Brain kept the capture as an item but marked it `failed`
        /// (nothing usable in it). Not retried: the item exists.
        case keptAsFailed(item: ULID)
        /// Already done, already has an item, or another worker has it.
        case nothingToDo
    }

    let database: Database
    /// Nil means rules only (T0): no model is called.
    let router: ModelRouter?
    let settings: EnrichmentSettings
    let clock: @Sendable () -> Date
    let logger: Logger

    public init(
        database: Database, router: ModelRouter?, settings: EnrichmentSettings = .init(),
        logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.router = router
        self.settings = settings
        self.logger = logger
        self.clock = clock
    }

    public func enrich(user: UserID, capture id: ULID) async throws -> Outcome {
        let store = database.scoped(to: user)
        let now = clock()
        guard
            let capture = try await store.claimCapture(
                id, now: now, stuckAfter: settings.stuckAfter)
        else { return .nothingToDo }

        do {
            return try await enrich(capture, store: store, user: user, now: now)
        } catch {
            // Hand it back as `failed` so a retry can claim it at once, rather
            // than waiting for the stuck timeout. Best effort: if this also
            // fails, the sweeper still finds it.
            _ = try? await store.setCaptureStatus(id, .failed)
            throw error
        }
    }

    private func enrich(_ capture: Capture, store: UserStore, user: UserID, now: Date)
        async throws -> Outcome
    {
        let timeZone =
            TimeZone(identifier: try await store.timezone() ?? "Asia/Kolkata")
            ?? TimeZone(identifier: "Asia/Kolkata")!
        var graph = try await store.graph()
        var ids = ULIDGenerator(seed: UInt64.random(in: .min ... .max))
        let result = await EnrichmentPipeline(timeZone: timeZone, router: router).enrich(
            capture: capture, graph: graph, now: now, idGenerator: &ids,
            requester: try await requester(for: user, now: now))

        // Guard 6, here as well as in Brain: every suggested link goes
        // through the graph's own rules before it can be stored.
        graph.insert(result.item)
        var edges: [Edge] = []
        for edge in result.suggestedEdges {
            do {
                edges.append(try graph.addEdge(edge))
            } catch {
                logger.warning(
                    "dropped a suggested link", metadata: ["reason": "\(error)"])
            }
        }
        // T3: what every tier abstained on becomes a question, stored with
        // the item or not at all. A field the server cannot apply an answer
        // to is counted and skipped, never stored half-usable.
        var questions: [StoredQuestion] = []
        var unanswerable = 0
        for question in result.questions {
            guard StoredQuestion.answerableFields.contains(question.field) else {
                unanswerable += 1
                continue
            }
            questions.append(
                StoredQuestion(
                    id: ids.next(), captureId: capture.id, itemId: result.item.id,
                    field: question.field, prompt: question.prompt, options: question.options,
                    createdAt: now))
        }
        if unanswerable > 0 {
            logger.warning(
                "skipped questions about fields the server cannot apply",
                metadata: ["count": "\(unanswerable)"])
        }

        let saved = try await store.saveEnrichment(
            capture: capture.id, status: result.capture.status, item: result.item, edges: edges,
            questions: questions)
        logTrace(result.trace, item: result.item, saved: saved)
        guard saved else { return .nothingToDo }
        return result.capture.status == .failed
            ? .keptAsFailed(item: result.item.id)
            : .enriched(item: result.item.id, edges: edges.count)
    }

    /// Each settled field's confidence, two decimals, fields in a fixed order.
    /// Values themselves are never included: they can quote the capture.
    static func confidences(_ item: Item) -> String {
        func entry<V: Sendable & Hashable>(_ name: String, _ field: Classified<V>) -> String? {
            field.value == nil ? nil : "\(name)=\(String(format: "%.2f", field.confidence))"
        }
        return [
            entry("category", item.category), entry("dueAt", item.dueAt),
            entry("effort", item.effort), entry("goalId", item.goalId),
            entry("type", item.type),
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// The per-user fair share of the first T2 rung's daily pool, sized by
    /// how many people captured something in the last day.
    private func requester(for user: UserID, now: Date) async throws -> Requester {
        guard router != nil else { return Requester(id: user.description, dailyLimit: nil) }
        let pool = ProductionRouter.decision1.limits.requestsPerDay ?? 10_000
        let active = try await database.activeUsers(since: now.addingTimeInterval(-86_400))
        return Requester(
            id: user.description,
            dailyLimit: BudgetLedger.fairShare(dailyLimit: pool, activeUsers: active))
    }

    /// Tiers, confidences and costs only. `trace.notes` can quote the
    /// capture, so it is never logged; nor is any field's value.
    ///
    /// Which *model* answered is not here: Brain's pipeline never learns
    /// which rung of the ladder answered, and `EnrichmentTrace` does not carry
    /// it (asked of Brain, 24 Nov).
    private func logTrace(_ trace: EnrichmentTrace, item: Item, saved: Bool) {
        logger.info(
            "capture enriched",
            metadata: [
                "saved": "\(saved)",
                "tiers": "\(trace.tierByField.mapValues(\.rawValue).sorted { $0.key < $1.key })",
                "confidence": "\(Self.confidences(item))",
                "unresolved": "\(trace.unresolved.sorted())",
                "asked": "\(trace.askUser.sorted())",
                "routed": "\(trace.routedCapabilities)",
                "tokens": "\(trace.estimatedTokens)",
                "redacted": "\(trace.redactedBeforeSending)",
            ])
    }
}
