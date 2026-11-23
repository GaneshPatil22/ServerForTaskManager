import API
import BrainCore
import Foundation

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
            createdAt: goal.createdAt)
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
