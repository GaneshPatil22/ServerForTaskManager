import BrainCore
import Foundation
import Testing

@testable import Storage

@Suite("Corrections export")
struct CorrectionsExportTests {
    let salt = "test-salt-0123456789"

    /// The export is deployment-wide and the test database is shared, so each
    /// test picks out its own rows by correction id.
    func exported(_ ids: Set<String>) async throws -> [ExportedCorrection] {
        try await TestDatabase.get().exportCorrections(since: nil, salt: salt)
            .filter { ids.contains($0.id) }
    }

    @Test func carriesContextButNotTheUserID() async throws {
        let store = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: store)
        let rows = try await exported([seed.correction.id.rawValue])
        let row = try #require(rows.first)
        #expect(row.field == "effort" && row.tier == "t2")
        #expect(row.before == "small" && row.after == "medium")
        #expect(row.target.kind == "item" && row.target.title == "call bank")
        #expect(row.target.captureText == "call bank re 50K loan")
        #expect(row.user.count == 16)
        let raw = store.user.rawValue.uuidString.lowercased()
        #expect(!row.user.contains(raw.prefix(8)))
    }

    @Test func pseudonymIsStablePerUserAndDiffersBetweenUsers() async throws {
        let a = try await TestDatabase.newUser()
        let b = try await TestDatabase.newUser()
        let seedA = try await Seed.insert(into: a)
        let seedB = try await Seed.insert(into: b)
        let extra = Correction(
            id: newID(), targetId: seedA.edge.id, field: "rejected", beforeValue: "false",
            afterValue: "true", tier: .t0, createdAt: fixedDate)
        try await a.insertCorrection(extra)
        let rows = try await exported([
            seedA.correction.id.rawValue, seedB.correction.id.rawValue, extra.id.rawValue,
        ])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let first = try #require(byID[seedA.correction.id.rawValue])
        let second = try #require(byID[extra.id.rawValue])
        let other = try #require(byID[seedB.correction.id.rawValue])
        #expect(first.user == second.user)
        #expect(first.user != other.user)
        // An edge target names both ends.
        #expect(second.target.kind == "edge" && second.target.edgeKind == "blocks")
        #expect(second.target.fromTitle == "call bank" && second.target.toTitle == "get loan")
    }

    /// A big-task swap is two item ids; the export makes it readable.
    @Test func idValuesGetTheirTitles() async throws {
        let store = try await TestDatabase.newUser()
        let seed = try await Seed.insert(into: store)
        let swap = Correction(
            id: newID(), targetId: seed.item.id, field: "bigTask",
            beforeValue: seed.item.id.rawValue, afterValue: seed.other.id.rawValue, tier: .t0,
            createdAt: fixedDate)
        try await store.insertCorrection(swap)
        let row = try #require(try await exported([swap.id.rawValue]).first)
        #expect(row.beforeTitle == "call bank" && row.afterTitle == "get loan")
    }
}
