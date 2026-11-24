import BrainCore
import Testing

@testable import Storage

/// The migration's CHECK lists are frozen text; Brain's enums can grow. If one
/// of these fails, Brain gained or renamed a case: write a new migration that
/// widens the CHECK. Never edit M0001.
@Suite("Schema matches Brain's enums")
struct SchemaDriftTests {
    typealias M = M0001_CoreTables

    func raw<T: CaseIterable & RawRepresentable>(_: T.Type) -> Set<String>
    where T.RawValue == String {
        Set(T.allCases.map(\.rawValue))
    }

    @Test func enumsMatch() {
        #expect(Set(M.tiers) == raw(Tier.self))
        #expect(Set(M.captureSources) == raw(CaptureSource.self))
        #expect(Set(M.captureStatuses) == raw(CaptureStatus.self))
        #expect(Set(M.itemTypes) == raw(ItemType.self))
        #expect(Set(M.itemStatuses) == raw(ItemStatus.self))
        #expect(Set(M.effortBuckets) == raw(EffortBucket.self))
        #expect(Set(M.taskCategories) == raw(TaskCategory.self))
        #expect(Set(M.goalStatuses) == raw(GoalStatus.self))
        #expect(Set(M.edgeKinds) == raw(EdgeKind.self))
        #expect(Set(M.edgeSources) == raw(EdgeSource.self))
        #expect(Set(M0005_Planner.commitmentKinds) == raw(CommitmentKind.self))
        #expect(Weekday.allCases.map(\.rawValue) == Array(1...7))
    }
}
