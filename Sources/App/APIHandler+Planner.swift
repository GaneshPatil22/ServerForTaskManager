import API
import BrainCore
import Foundation
import Storage

// The planner (`Brain/docs/15-planner.md`). Commitments are scheduled, never
// ranked: nothing here touches `ranked`, and the plan carries them as their
// own section. Every "today" is the user's, from their timezone.

extension APIHandler.Stop {
    init(_ refusal: PlannerRefusal, _ what: String) {
        switch refusal {
        case .unknownReference: self = .notFound(what)
        }
    }

    static func badRequest(_ code: String, _ message: String) -> Self {
        .init(status: 400, code: code, message: message)
    }
}

extension APIHandler {
    /// How far back done days are read for streaks. A streak longer than
    /// this reads as this long; nobody is harmed by "400 days".
    static let streakHistoryDays = 400

    /// The user's today, and the calendar it came from.
    func today(_ store: UserStore) async throws -> (day: CalendarDay, calendar: Calendar) {
        let calendar = try await calendar(for: store)
        return (CalendarDay(clock(), in: calendar.timeZone), calendar)
    }

    func completed(_ store: UserStore, today: CalendarDay) async throws
        -> [ULID: Set<CalendarDay>]
    {
        try await store.completedDays(since: today.adding(days: -Self.streakHistoryDays))
    }

    /// A live (not deleted) commitment, or 404.
    func liveCommitment(_ store: UserStore, _ id: ULID) async throws -> StoredCommitment {
        guard let stored = try await store.commitment(id), !stored.archived else {
            throw Stop.notFound("commitment")
        }
        return stored
    }

    // MARK: - Commitments

    func listCommitments(_ input: Operations.ListCommitments.Input) async throws
        -> Operations.ListCommitments.Output
    {
        try await run(
            {
                let store = try await store()
                let (today, _) = try await today(store)
                let done = try await completed(store, today: today)
                let list = try await store.commitments().map {
                    Components.Schemas.Commitment(
                        $0, completed: done[$0.commitment.id] ?? [], today: today)
                }
                return .ok(.init(body: .json(.init(commitments: list))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func createCommitment(_ input: Operations.CreateCommitment.Input) async throws
        -> Operations.CreateCommitment.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let store = try await store()
                let (today, _) = try await today(store)
                let commitment = try check { () throws(Validation.Failure) in
                    let startOn =
                        try Validation.optionalDay(body.startOn, field: "startOn") ?? today
                    let endOn = try Validation.optionalDay(body.endOn, field: "endOn")
                    if let endOn, endOn < startOn {
                        throw Validation.Failure(
                            code: "invalid_window", message: "endOn must not be before startOn")
                    }
                    return Commitment(
                        id: try Validation.ulid(body.id, field: "id"),
                        title: try Validation.text(
                            body.title, field: "title", max: Validation.maxCommitmentTitleLength),
                        kind: convert(body.kind), rule: try Validation.rule(body.rule),
                        minutes: try Validation.minutes(body.minutes),
                        category: body.category.map { convert($0) },
                        goalId: try Validation.optionalULID(body.goalId, field: "goalId"),
                        startOn: startOn, endOn: endOn, paused: body.paused ?? false,
                        note: try Validation.note(body.note))
                }
                let now = clock()
                let result: (commitment: StoredCommitment, created: Bool)
                do {
                    result = try await store.insertCommitment(
                        StoredCommitment(commitment: commitment, createdAt: now, updatedAt: now))
                } catch let refusal as PlannerRefusal {
                    throw Stop(refusal, "goal")
                }
                let done = try await completed(store, today: today)
                let json = Components.Schemas.Commitment(
                    result.commitment, completed: done[commitment.id] ?? [], today: today)
                return result.created
                    ? .created(.init(body: .json(json))) : .ok(.init(body: .json(json)))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func getCommitment(_ input: Operations.GetCommitment.Input) async throws
        -> Operations.GetCommitment.Output
    {
        try await run(
            {
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                let store = try await store()
                let stored = try await liveCommitment(store, id)
                let (today, _) = try await today(store)
                let done = try await completed(store, today: today)
                return .ok(
                    .init(body: .json(.init(stored, completed: done[id] ?? [], today: today))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func updateCommitment(_ input: Operations.UpdateCommitment.Input) async throws
        -> Operations.UpdateCommitment.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                let store = try await store()
                var stored = try await liveCommitment(store, id)
                let clear = Set(body.clear ?? [])
                stored.commitment = try check { () throws(Validation.Failure) in
                    var c = stored.commitment
                    let sent: [Components.Schemas.CommitmentUpdate.ClearPayloadPayload: Bool] = [
                        .category: body.category != nil, .goalId: body.goalId != nil,
                        .endOn: body.endOn != nil, .note: body.note != nil,
                    ]
                    if let both = clear.first(where: { sent[$0] == true }) {
                        throw Validation.Failure(
                            code: "conflicting_clear",
                            message: "\(both.rawValue) is both sent and cleared")
                    }
                    if let title = body.title {
                        c.title = try Validation.text(
                            title, field: "title", max: Validation.maxCommitmentTitleLength)
                    }
                    if let kind = body.kind { c.kind = convert(kind) }
                    if let rule = body.rule { c.rule = try Validation.rule(rule) }
                    if let minutes = body.minutes { c.minutes = try Validation.minutes(minutes) }
                    if let category = body.category { c.category = convert(category) }
                    if let goalId = body.goalId {
                        c.goalId = try Validation.ulid(goalId, field: "goalId")
                    }
                    if let startOn = body.startOn {
                        c.startOn = try Validation.day(startOn, field: "startOn")
                    }
                    if let endOn = body.endOn {
                        c.endOn = try Validation.day(endOn, field: "endOn")
                    }
                    if let paused = body.paused { c.paused = paused }
                    if body.note != nil { c.note = try Validation.note(body.note) }
                    if clear.contains(.category) { c.category = nil }
                    if clear.contains(.goalId) { c.goalId = nil }
                    if clear.contains(.endOn) { c.endOn = nil }
                    if clear.contains(.note) { c.note = nil }
                    if let endOn = c.endOn, endOn < c.startOn {
                        throw Validation.Failure(
                            code: "invalid_window", message: "endOn must not be before startOn")
                    }
                    return c
                }
                stored.updatedAt = clock()
                do {
                    try await store.replaceCommitment(stored)
                } catch let refusal as PlannerRefusal {
                    throw Stop(refusal, "goal")
                }
                let (today, _) = try await today(store)
                let done = try await completed(store, today: today)
                return .ok(
                    .init(body: .json(.init(stored, completed: done[id] ?? [], today: today))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    /// Archives, and ends the commitment today, so the days after it are
    /// not counted as missed in any review. Its done days stay.
    func deleteCommitment(_ input: Operations.DeleteCommitment.Input) async throws
        -> Operations.DeleteCommitment.Output
    {
        try await run(
            {
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                let store = try await store()
                var stored = try await liveCommitment(store, id)
                let (today, _) = try await today(store)
                let c = stored.commitment
                stored.commitment.endOn = max(c.startOn, min(c.endOn ?? today, today))
                stored.archived = true
                stored.updatedAt = clock()
                try await store.replaceCommitment(stored)
                return .noContent(.init())
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Occurrences

    func setOccurrence(_ input: Operations.SetOccurrence.Input) async throws
        -> Operations.SetOccurrence.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (id, day, movedTo) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(input.path.id, field: "id"),
                        try Validation.day(input.path.day, field: "day"),
                        try Validation.optionalDay(body.movedTo, field: "movedTo")
                    )
                }
                let store = try await store()
                let stored = try await liveCommitment(store, id)
                guard stored.commitment.falls(on: day) else {
                    throw Stop.badRequest(
                        "not_scheduled", "this commitment does not fall on \(day)")
                }
                let (today, _) = try await today(store)
                let existing = try await store.occurrences(from: day, through: day)
                    .first { $0.commitmentId == id && $0.day == day }
                let state: OccurrenceState = convert(body.state)
                var target: CalendarDay?
                switch state {
                case .moved:
                    guard let movedTo, movedTo != day else {
                        throw Stop.badRequest("invalid_move", "moved needs a different movedTo")
                    }
                    target = movedTo
                case .done, .skipped:
                    guard movedTo == nil else {
                        throw Stop.badRequest("invalid_move", "movedTo is only for moved")
                    }
                    // Done after a move: keep where it was done.
                    if state == .done, let existing, existing.state != .skipped {
                        target = existing.movedTo
                    }
                }
                if state == .done, (target ?? day) > today {
                    throw Stop.badRequest("in_future", "that day has not come yet")
                }
                let record: OccurrenceRecord
                do {
                    record = try await store.setOccurrence(
                        id, day: day, state: state, movedTo: target, at: clock())
                } catch let refusal as PlannerRefusal {
                    throw Stop(refusal, "commitment")
                }
                return .ok(.init(body: .json(.init(record))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func clearOccurrence(_ input: Operations.ClearOccurrence.Input) async throws
        -> Operations.ClearOccurrence.Output
    {
        try await run(
            {
                let (id, day) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(input.path.id, field: "id"),
                        try Validation.day(input.path.day, field: "day")
                    )
                }
                let store = try await store()
                _ = try await liveCommitment(store, id)
                try await store.clearOccurrence(id, day: day)
                return .noContent(.init())
            }, problem: { .default(statusCode: $0, $1) })
    }

    func listOccurrences(_ input: Operations.ListOccurrences.Input) async throws
        -> Operations.ListOccurrences.Output
    {
        try await run(
            {
                let (from, through) = try check { () throws(Validation.Failure) in
                    try Validation.range(from: input.query.from, through: input.query.through)
                }
                let store = try await store()
                let commitments = try await store.commitments()
                let rows = try await store.occurrences(from: from, through: through)
                var byKey: [String: OccurrenceRecord] = [:]
                for row in rows { byKey["\(row.commitmentId)|\(row.day)"] = row }

                var out: [(place: CalendarDay, json: Components.Schemas.Occurrence)] = []
                let live = Set(commitments.map(\.commitment.id))
                for stored in commitments {
                    let c = stored.commitment
                    for day in c.days(from: from, through: through) {
                        let row = byKey.removeValue(forKey: "\(c.id)|\(day)")
                        out.append(
                            (
                                row?.movedTo ?? day,
                                .init(
                                    commitmentId: c.id.rawValue, day: day.description,
                                    state: row.map { convert($0.state) },
                                    movedTo: row?.movedTo?.description)
                            ))
                    }
                }
                // Moved in from outside the range.
                for row in byKey.values where live.contains(row.commitmentId) {
                    if let place = row.movedTo, place >= from, place <= through {
                        out.append((place, .init(row)))
                    }
                }
                // By where it shows, then commitment, then its own day, so an
                // occurrence moved onto a day sits before that day's own one.
                out.sort {
                    ($0.place, $0.json.commitmentId, $0.json.day)
                        < ($1.place, $1.json.commitmentId, $1.json.day)
                }
                return .ok(.init(body: .json(.init(occurrences: out.map(\.json)))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Journal

    func listJournal(_ input: Operations.ListJournal.Input) async throws
        -> Operations.ListJournal.Output
    {
        try await run(
            {
                let (from, through) = try check { () throws(Validation.Failure) in
                    try Validation.range(from: input.query.from, through: input.query.through)
                }
                let entries = try await store().journal(from: from, through: through)
                return .ok(
                    .init(
                        body: .json(
                            .init(entries: entries.map(Components.Schemas.JournalEntry.init)))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func writeJournal(_ input: Operations.WriteJournal.Input) async throws
        -> Operations.WriteJournal.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (day, text) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.day(input.path.day, field: "day"),
                        try Validation.text(
                            body.body, field: "body", max: Validation.maxJournalLength)
                    )
                }
                let store = try await store()
                guard try await day <= today(store).day else {
                    throw Stop.badRequest("in_future", "that day has not come yet")
                }
                let entry = try await store.writeJournal(day: day, body: text, at: clock())
                return .ok(.init(body: .json(.init(entry))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func deleteJournal(_ input: Operations.DeleteJournal.Input) async throws
        -> Operations.DeleteJournal.Output
    {
        try await run(
            {
                let day = try check { () throws(Validation.Failure) in
                    try Validation.day(input.path.day, field: "day")
                }
                try await store().deleteJournal(day: day)
                return .noContent(.init())
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Daily plan (D4)

    func listDailyPlans(_ input: Operations.ListDailyPlans.Input) async throws
        -> Operations.ListDailyPlans.Output
    {
        try await run(
            {
                let (from, through) = try check { () throws(Validation.Failure) in
                    try Validation.range(from: input.query.from, through: input.query.through)
                }
                let plans = try await store().dailyPlans(from: from, through: through)
                return .ok(
                    .init(body: .json(.init(plans: plans.map(Components.Schemas.DailyPlan.init)))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func confirmDailyPlan(_ input: Operations.ConfirmDailyPlan.Input) async throws
        -> Operations.ConfirmDailyPlan.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (day, itemId, proposedId) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.day(input.path.day, field: "day"),
                        try Validation.ulid(body.itemId, field: "itemId"),
                        try Validation.optionalULID(body.proposedItemId, field: "proposedItemId")
                    )
                }
                let store = try await store()
                let (today, _) = try await today(store)
                guard abs(Validation.daysBetween(today, day)) <= 1 else {
                    throw Stop.badRequest(
                        "day_out_of_range",
                        "a big task is confirmed for yesterday, today or tomorrow")
                }
                guard let item = try await store.item(itemId) else { throw Stop.notFound("item") }
                guard item.status == .open else {
                    throw Stop.badRequest("item_not_open", "that item is already finished")
                }
                // Brain's own rule for what the plan holds (0.11.0: not ideas or
                // notes; an item whose type is still unknown is in). Checked
                // here too, or the exclusion would hold on read and not on write.
                guard Scoring.appearsInPlan(item) else {
                    throw Stop.badRequest(
                        "item_not_actionable",
                        "ideas and notes are not planned; make it a task first")
                }
                if let proposedId {
                    guard let proposed = try await store.item(proposedId) else {
                        throw Stop.notFound("item")
                    }
                    // A swap is recorded as "Brain proposed this". Brain never
                    // proposes an idea or a note, so that record would be false.
                    guard Scoring.appearsInPlan(proposed) else {
                        throw Stop.badRequest(
                            "item_not_actionable",
                            "Brain does not propose ideas or notes as the big task")
                    }
                }
                let plan: DailyPlan
                do {
                    plan = try await store.confirmDailyPlan(
                        day: day, itemId: itemId, proposedItemId: proposedId, at: clock(),
                        correction: newULID())
                } catch let refusal as PlannerRefusal {
                    throw Stop(refusal, "item")
                }
                return .ok(.init(body: .json(.init(plan))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Review

    func getReview(_ input: Operations.GetReview.Input) async throws
        -> Operations.GetReview.Output
    {
        try await run(
            {
                let (from, through) = try check { () throws(Validation.Failure) in
                    try Validation.range(from: input.query.from, through: input.query.through)
                }
                let store = try await store()
                let (today, _) = try await today(store)
                let done = try await completed(store, today: today)
                let rows = try await store.occurrences(from: from, through: through)
                var byKey: [String: OccurrenceRecord] = [:]
                for row in rows { byKey["\(row.commitmentId)|\(row.day)"] = row }

                var reviews: [Components.Schemas.CommitmentReview] = []
                // Deleted ones too: their history is the point of a review.
                for stored in try await store.commitments(includeArchived: true) {
                    let c = stored.commitment
                    let expected = c.days(from: from, through: through)
                    guard !expected.isEmpty else { continue }
                    var counts = (done: 0, skipped: 0, moved: 0, missed: 0)
                    for day in expected {
                        let row = byKey["\(c.id)|\(day)"]
                        switch row?.state {
                        case .done: counts.done += 1
                        case .skipped: counts.skipped += 1
                        case .moved:
                            if let to = row?.movedTo, to < today {
                                counts.missed += 1
                            } else {
                                counts.moved += 1
                            }
                        case nil:
                            if day < today { counts.missed += 1 }
                        }
                    }
                    let completed = done[c.id] ?? []
                    reviews.append(
                        .init(
                            commitment: .init(stored, completed: completed, today: today),
                            expected: expected.count, done: counts.done, skipped: counts.skipped,
                            moved: counts.moved, missed: counts.missed,
                            hitRate: c.hitRate(completed: completed, from: from, through: through),
                            streak: stored.archived
                                ? 0 : c.streak(completed: completed, today: today)
                        ))
                }

                // Goals whose month or quarter overlaps the range.
                var graph = BrainGraph()
                let goals = try await store.goals()
                for goal in goals { graph.insert(goal) }
                let overlapping = goals.filter { goal in
                    guard let p = goal.period else { return false }
                    return p.start <= through && p.end >= from
                }
                let goalReviews = overlapping.map { goal in
                    Components.Schemas.GoalReview(
                        goal: .init(goal),
                        children: graph.children(of: goal.id).map(Components.Schemas.Goal.init))
                }

                let plans = try await store.dailyPlans(from: from, through: through)
                return .ok(
                    .init(
                        body: .json(
                            .init(
                                from: from.description, through: through.description,
                                commitments: reviews, goals: goalReviews,
                                journalEntries: try await store.journal(
                                    from: from, through: through
                                ).count,
                                bigTasksConfirmed: plans.count,
                                bigTasksSwapped: plans.filter(\.swapped).count))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - The plan's commitments section

    /// Today's commitments as the plan shows them: Brain's section, with each
    /// occurrence's recorded state, plus anything moved into today.
    func commitmentsSection(
        _ outputs: BrainOutputs, stored: [StoredCommitment],
        completed: [ULID: Set<CalendarDay>], store: UserStore
    ) async throws -> (section: [Components.Schemas.ScheduledCommitment], owedMinutes: Int) {
        let today = outputs.day
        let rows = try await store.occurrences(from: today, through: today)
        let byID = Dictionary(
            stored.map { ($0.commitment.id, $0) }, uniquingKeysWith: { a, _ in a })
        var section: [Components.Schemas.ScheduledCommitment] = []
        var owed: [ScheduledCommitment] = []

        for scheduled in outputs.commitments {
            let c = scheduled.commitment
            guard let s = byID[c.id] else { continue }
            let row = rows.first { $0.commitmentId == c.id && $0.day == today }
            section.append(
                .init(
                    commitment: .init(s, completed: completed[c.id] ?? [], today: today),
                    state: row.map { convert($0.state) },
                    movedTo: row?.state == .moved ? row?.movedTo?.description : nil))
            // Anything with a state is not owed today: done, skipped, or moved away.
            owed.append(ScheduledCommitment(commitment: c, day: today, done: row != nil))
        }
        for row in rows where row.day != today && row.movedTo == today {
            guard let s = byID[row.commitmentId] else { continue }
            section.append(
                .init(
                    commitment: .init(
                        s, completed: completed[row.commitmentId] ?? [], today: today),
                    state: row.state == .done ? .done : nil, movedFrom: row.day.description))
            owed.append(
                ScheduledCommitment(commitment: s.commitment, day: today, done: row.state == .done))
        }
        return (section, Commitment.committedMinutes(owed))
    }
}
