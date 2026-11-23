import API
import BrainCore
import Foundation
import Storage
import Worker

/// The API. Every handler gets its user from `RequestUser`, set by
/// `AuthMiddleware`, and reaches data only through `UserStore`.
///
/// Expected failures are returned as the spec's `Problem` responses, never
/// thrown. An unknown id and another user's id both give the same 404.
struct APIHandler: APIProtocol {
    let database: Database
    let enrichment: any EnrichmentEnqueuing
    let users: KnownUsers
    let clock: @Sendable () -> Date

    init(
        database: Database, enrichment: any EnrichmentEnqueuing,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.enrichment = enrichment
        self.users = KnownUsers()
        self.clock = clock
    }

    /// Why a handler stopped early. Turned into a `Problem` at the edge.
    struct Stop: Error {
        let status: Int
        let code: String
        let message: String

        static let unauthenticated = Stop(
            status: 401, code: "unauthenticated", message: "sign in again")
        static func notFound(_ what: String) -> Stop {
            Stop(status: 404, code: "not_found", message: "no such \(what)")
        }
        static func invalid(_ failure: Validation.Failure) -> Stop {
            Stop(status: 400, code: failure.code, message: failure.message)
        }
        init(status: Int, code: String, message: String) {
            self.status = status
            self.code = code
            self.message = message
        }

        init(_ refusal: UserStore.LinkRefusal) {
            switch refusal {
            case .cycle:
                self.init(status: 409, code: "cycle", message: "this link would make a loop")
            case .selfLink:
                self.init(status: 400, code: "self_link", message: "an item cannot link to itself")
            case .unknownEndpoint:
                self.init(status: 404, code: "not_found", message: "no such item or goal")
            case .wrongTarget:
                self.init(
                    status: 400, code: "wrong_target",
                    message: "serves links point at a goal; other links point at an item")
            }
        }

        static let notYet = Stop(
            status: 501, code: "not_implemented", message: "this endpoint arrives in a later step")

        var problem: Components.Responses.Problem {
            .init(body: .json(.init(code: code, message: message)))
        }
    }

    /// The caller's store, creating their `users` row the first time this
    /// process sees them.
    func store() async throws -> UserStore {
        guard let user = RequestUser.current else { throw Stop.unauthenticated }
        let store = database.scoped(to: user)
        if await !users.contains(user) {
            try await store.ensureUser()
            await users.insert(user)
        }
        return store
    }

    func check<T>(_ body: () throws(Validation.Failure) -> T) throws -> T {
        do { return try body() } catch { throw Stop.invalid(error) }
    }

    /// Runs `body`; a `Stop` becomes the operation's `default` response.
    func run<Output>(
        _ body: () async throws -> Output,
        problem: (Int, Components.Responses.Problem) -> Output
    ) async throws -> Output {
        do {
            return try await body()
        } catch let stop as Stop {
            return problem(stop.status, stop.problem)
        }
    }

    // MARK: - Me

    func getMe(_ input: Operations.GetMe.Input) async throws -> Operations.GetMe.Output {
        try await run(
            {
                let store = try await store()
                return .ok(.init(body: .json(try await me(store))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func updateMe(_ input: Operations.UpdateMe.Input) async throws -> Operations.UpdateMe.Output {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let timezone = try check { () throws(Validation.Failure) in
                    try Validation.timezone(body.timezone)
                }
                let store = try await store()
                try await store.setTimezone(timezone)
                return .ok(.init(body: .json(try await me(store))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    private func me(_ store: UserStore) async throws -> Components.Schemas.Me {
        .init(
            userId: store.user.rawValue.uuidString.lowercased(),
            timezone: try await store.timezone() ?? "Asia/Kolkata")
    }

    // MARK: - Captures

    func createCapture(_ input: Operations.CreateCapture.Input) async throws
        -> Operations.CreateCapture.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (id, text) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(body.id, field: "id"),
                        try Validation.text(
                            body.text, field: "text", max: Validation.maxCaptureLength)
                    )
                }
                let now = clock()
                // A future timestamp (a wrong phone clock) becomes now. A capture is
                // never refused for its time: refusing risks losing it on the device.
                let capturedAt = min(body.capturedAt ?? now, now)
                let capture = Capture(
                    id: id, rawText: text,
                    source: body.source.map { convert($0) } ?? .text,
                    createdAt: capturedAt, status: .raw)

                let store = try await store()
                let (stored, created) = try await store.insertCapture(capture)
                // Queued only after the capture is committed. If this push is
                // lost, the sweeper queues it later; the capture is already safe.
                if created { await enrichment.enqueue(user: store.user, capture: stored.id) }
                let json = Components.Schemas.Capture(stored)
                return created ? .created(.init(body: .json(json))) : .ok(.init(body: .json(json)))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func listCaptures(_ input: Operations.ListCaptures.Input) async throws
        -> Operations.ListCaptures.Output
    {
        try await run(
            {
                let (after, limit) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.optionalULID(input.query.after, field: "after"),
                        try Validation.limit(input.query.limit)
                    )
                }
                let rows = try await store().captures(
                    after: after, limit: limit + 1, status: input.query.status.map { convert($0) })
                let page = Page(rows, limit: limit, id: \.id)
                return .ok(
                    .init(
                        body: .json(
                            .init(
                                captures: page.rows.map(Components.Schemas.Capture.init),
                                nextCursor: page.nextCursor))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func getCapture(_ input: Operations.GetCapture.Input) async throws
        -> Operations.GetCapture.Output
    {
        try await run(
            {
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                guard let capture = try await store().capture(id) else {
                    throw Stop.notFound("capture")
                }
                return .ok(.init(body: .json(.init(capture))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Items

    func listItems(_ input: Operations.ListItems.Input) async throws -> Operations.ListItems.Output
    {
        try await run(
            {
                let (after, limit) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.optionalULID(input.query.after, field: "after"),
                        try Validation.limit(input.query.limit)
                    )
                }
                let rows = try await store().items(
                    after: after, limit: limit + 1, status: input.query.status.map { convert($0) })
                let page = Page(rows, limit: limit, id: \.id)
                return .ok(
                    .init(
                        body: .json(
                            .init(
                                items: page.rows.map(Components.Schemas.Item.init),
                                nextCursor: page.nextCursor))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func getItem(_ input: Operations.GetItem.Input) async throws -> Operations.GetItem.Output {
        try await run(
            {
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                guard let item = try await store().item(id) else { throw Stop.notFound("item") }
                return .ok(.init(body: .json(.init(item))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Goals

    func listGoals(_ input: Operations.ListGoals.Input) async throws -> Operations.ListGoals.Output
    {
        try await run(
            {
                let goals = try await store().goals()
                return .ok(
                    .init(body: .json(.init(goals: goals.map(Components.Schemas.Goal.init)))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func createGoal(_ input: Operations.CreateGoal.Input) async throws
        -> Operations.CreateGoal.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (id, title) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(body.id, field: "id"),
                        try Validation.text(
                            body.title, field: "title", max: Validation.maxTitleLength)
                    )
                }
                let (stored, created) = try await store().insertGoal(
                    Goal(id: id, title: title, createdAt: clock()))
                let json = Components.Schemas.Goal(stored)
                return created ? .created(.init(body: .json(json))) : .ok(.init(body: .json(json)))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func updateGoal(_ input: Operations.UpdateGoal.Input) async throws
        -> Operations.UpdateGoal.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (id, title) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(input.path.id, field: "id"),
                        try body.title.map { title throws(Validation.Failure) in
                            try Validation.text(
                                title, field: "title", max: Validation.maxTitleLength)
                        }
                    )
                }
                guard
                    let goal = try await store().updateGoal(
                        id, title: title, status: body.status.map { convert($0) })
                else { throw Stop.notFound("goal") }
                return .ok(.init(body: .json(.init(goal))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Later steps (501 until then)

    func updateItem(_ input: Operations.UpdateItem.Input) async throws
        -> Operations.UpdateItem.Output
    { .default(statusCode: 501, Stop.notYet.problem) }

    // MARK: - Plan

    /// Brain's deterministic ranking of the user's own graph, in their
    /// timezone. No model takes part (`Brain.compute`).
    func getPlan(_ input: Operations.GetPlan.Input) async throws -> Operations.GetPlan.Output {
        try await run(
            {
                let store = try await store()
                let now = clock()
                let outputs = BrainCore.Brain.compute(
                    graph: try await store.graph(), now: now,
                    calendar: try await calendar(for: store))
                return .ok(
                    .init(
                        body: .json(
                            .init(
                                next: outputs.next.map(Components.Schemas.RankedItem.init),
                                ranked: outputs.ranked.map(Components.Schemas.RankedItem.init),
                                quickWins: outputs.quickWins.map(
                                    Components.Schemas.RankedItem.init),
                                blocked: outputs.blocked.map(Components.Schemas.BlockedItem.init),
                                computedAt: now))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    /// "Today" is always the user's today, never the server's.
    func calendar(for store: UserStore) async throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone =
            TimeZone(identifier: try await store.timezone() ?? "Asia/Kolkata")
            ?? TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    func listEdges(_ input: Operations.ListEdges.Input) async throws -> Operations.ListEdges.Output
    {
        try await run(
            {
                let edges = try await store().edges(confirmed: input.query.confirmed)
                return .ok(
                    .init(body: .json(.init(edges: edges.map(Components.Schemas.Edge.init)))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Links (S5b)

    func createEdge(_ input: Operations.CreateEdge.Input) async throws
        -> Operations.CreateEdge.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (id, from, to) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(body.id, field: "id"),
                        try Validation.ulid(body.from, field: "from"),
                        try Validation.ulid(body.to, field: "to")
                    )
                }
                let edge = Edge(
                    id: id, from: from, to: to, kind: convert(body.kind), confidence: 1,
                    source: .user, confirmed: true)
                do {
                    switch try await store().createUserLink(edge) {
                    case .created(let stored):
                        return .created(.init(body: .json(.init(stored))))
                    case .existing(let stored):
                        return .ok(.init(body: .json(.init(stored))))
                    }
                } catch let refusal as UserStore.LinkRefusal {
                    throw Stop(refusal)
                }
            }, problem: { .default(statusCode: $0, $1) })
    }

    func confirmEdge(_ input: Operations.ConfirmEdge.Input) async throws
        -> Operations.ConfirmEdge.Output
    {
        try await run(
            {
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                guard
                    let edge = try await store().confirmSuggestion(
                        id, correction: newULID(), at: clock())
                else { throw Stop.notFound("link") }
                return .ok(.init(body: .json(.init(edge))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func rejectEdge(_ input: Operations.RejectEdge.Input) async throws
        -> Operations.RejectEdge.Output
    {
        try await run(
            {
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                guard try await store().rejectLink(id, correction: newULID(), at: clock()) else {
                    throw Stop.notFound("link")
                }
                return .noContent(.init())
            }, problem: { .default(statusCode: $0, $1) })
    }

    /// Ids the server mints itself (corrections). Random seed, real clock.
    func newULID() -> ULID {
        var generator = ULIDGenerator(seed: UInt64.random(in: .min ... .max))
        return generator.next()
    }

    func listQuestions(_ input: Operations.ListQuestions.Input) async throws
        -> Operations.ListQuestions.Output
    { .default(statusCode: 501, Stop.notYet.problem) }

    func answerQuestion(_ input: Operations.AnswerQuestion.Input) async throws
        -> Operations.AnswerQuestion.Output
    { .default(statusCode: 501, Stop.notYet.problem) }
}

/// Users whose row already exists, so `ensureUser` runs once per user per
/// process instead of on every request. Rows are never deleted, so a cached
/// "exists" can't go stale.
actor KnownUsers {
    private var ids: Set<UserID> = []
    func contains(_ user: UserID) -> Bool { ids.contains(user) }
    func insert(_ user: UserID) { ids.insert(user) }
}

/// A page of rows fetched with `limit + 1`: the extra row only proves there
/// is a next page.
struct Page<Row> {
    let rows: [Row]
    let nextCursor: String?

    init(_ fetched: [Row], limit: Int, id: (Row) -> ULID) {
        if fetched.count > limit {
            rows = Array(fetched.prefix(limit))
            nextCursor = rows.last.map { id($0).rawValue }
        } else {
            rows = fetched
            nextCursor = nil
        }
    }
}
