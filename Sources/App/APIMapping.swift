import API
import BrainCore
import Foundation
import Storage

/// Brain's domain types → the API's generated types.
///
/// Enums convert through their raw values, which the spec copies from Brain.
/// `APIDriftTests` checks every case of every pair, so the force-unwrap in
/// `convert` cannot fail for a value that passed those tests.
func convert<From: RawRepresentable, To: RawRepresentable>(_ value: From, to: To.Type = To.self)
    -> To where From.RawValue == String, To.RawValue == String
{
    guard let converted = To(rawValue: value.rawValue) else {
        preconditionFailure("\(From.self).\(value.rawValue) has no \(To.self) case")
    }
    return converted
}

extension Components.Schemas.Span {
    init?(_ span: BrainCore.Span?) {
        guard let span else { return nil }
        self.init(start: span.start, end: span.end)
    }
}

extension Components.Schemas.Capture {
    init(_ capture: BrainCore.Capture) {
        self.init(
            id: capture.id.rawValue, text: capture.rawText, source: convert(capture.source),
            status: convert(capture.status), capturedAt: capture.createdAt)
    }
}

extension Components.Schemas.Goal {
    init(_ goal: BrainCore.Goal) {
        self.init(
            id: goal.id.rawValue, title: goal.title, status: convert(goal.status),
            createdAt: goal.createdAt, period: goal.period?.description,
            periodText: goal.period?.text, parentId: goal.parentId?.rawValue)
    }
}

extension Components.Schemas.Item {
    init(_ item: BrainCore.Item) {
        self.init(
            id: item.id.rawValue, captureId: item.captureId?.rawValue, title: item.title,
            status: convert(item.status),
            _type: .init(
                value: item.type.value.map { convert($0) }, confidence: item.type.confidence,
                decidedBy: convert(item.type.tier), evidence: .init(item.type.evidence)),
            effort: .init(
                value: item.effort.value.map { convert($0) }, confidence: item.effort.confidence,
                decidedBy: convert(item.effort.tier), evidence: .init(item.effort.evidence)),
            dueAt: .init(
                value: item.dueAt.value, confidence: item.dueAt.confidence,
                decidedBy: convert(item.dueAt.tier), evidence: .init(item.dueAt.evidence)),
            goal: .init(
                value: item.goalId.value?.rawValue, confidence: item.goalId.confidence,
                decidedBy: convert(item.goalId.tier), evidence: .init(item.goalId.evidence)),
            category: .init(
                value: item.category.value.map { convert($0) },
                confidence: item.category.confidence,
                decidedBy: convert(item.category.tier), evidence: .init(item.category.evidence)),
            createdAt: item.createdAt, updatedAt: item.updatedAt)
    }
}

extension Components.Schemas.RankedItem {
    init(_ ranked: BrainCore.RankedItem) {
        let b = ranked.breakdown
        self.init(
            item: .init(ranked.item), reason: ranked.reason,
            why: .init(
                unblocks: b.unblockedConfirmed, mayUnblock: b.unblockedAdditional,
                servesGoals: b.goalsConfirmed, mayServeGoals: b.goalsAdditional,
                duePressure: b.duePressure))
    }
}

extension Components.Schemas.BlockedItem {
    init(_ blocked: BrainCore.BlockedItem) {
        self.init(item: .init(blocked.item), blockedBy: blocked.blockers.map(\.id.rawValue))
    }
}

extension Components.Schemas.Edge {
    init(_ edge: BrainCore.Edge) {
        self.init(
            id: edge.id.rawValue, from: edge.from.rawValue, to: edge.to.rawValue,
            kind: convert(edge.kind), confidence: edge.confidence,
            suggestedBy: convert(edge.source), confirmed: edge.confirmed)
    }
}

// MARK: - Planner (P4)

extension BrainCore.Weekday {
    init(_ weekday: Components.Schemas.Weekday) {
        self = Self.allCases.first { $0.name.lowercased() == weekday.rawValue }!
    }
}

extension Components.Schemas.Weekday {
    init(_ weekday: BrainCore.Weekday) {
        self.init(rawValue: weekday.name.lowercased())!
    }
}

extension Components.Schemas.Rule {
    init(_ rule: RecurrenceRule) {
        switch rule {
        case .daily:
            self.init(kind: .daily)
        case .weeklyOn(let w):
            self.init(kind: .weeklyOn, weekday: .init(w))
        case .monthlyOnDay(let d):
            self.init(kind: .monthlyOnDay, day: d)
        case .monthlyOnNthWeekday(let n, let w):
            self.init(kind: .monthlyOnNthWeekday, weekday: .init(w), n: n)
        case .quarterlyOnNthWeekday(let n, let w):
            self.init(kind: .quarterlyOnNthWeekday, weekday: .init(w), n: n)
        }
    }
}

extension Components.Schemas.Commitment {
    /// `completed` is this commitment's done days; `today` the user's today.
    init(_ stored: StoredCommitment, completed: Set<CalendarDay>, today: CalendarDay) {
        let c = stored.commitment
        self.init(
            id: c.id.rawValue, title: c.title, kind: convert(c.kind), rule: .init(c.rule),
            ruleText: c.rule.text, minutes: c.minutes, category: c.category.map { convert($0) },
            goalId: c.goalId?.rawValue, startOn: c.startOn.description,
            endOn: c.endOn?.description, paused: c.paused, note: c.note,
            streak: c.streak(completed: completed, today: today),
            nextOn: c.next(onOrAfter: today)?.description, createdAt: stored.createdAt,
            updatedAt: stored.updatedAt)
    }
}

extension Components.Schemas.Occurrence {
    init(_ record: OccurrenceRecord) {
        self.init(
            commitmentId: record.commitmentId.rawValue, day: record.day.description,
            state: convert(record.state), movedTo: record.movedTo?.description)
    }
}

extension Components.Schemas.JournalEntry {
    init(_ entry: Storage.JournalEntry) {
        self.init(
            day: entry.day.description, body: entry.body, createdAt: entry.createdAt,
            updatedAt: entry.updatedAt)
    }
}

extension Components.Schemas.DailyPlan {
    init(_ plan: Storage.DailyPlan) {
        self.init(
            day: plan.day.description, itemId: plan.itemId.rawValue,
            proposedItemId: plan.proposedItemId?.rawValue, swapped: plan.swapped,
            confirmedAt: plan.confirmedAt)
    }
}
