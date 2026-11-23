import BrainHarness
import Foundation
import Testing

@testable import Storage

/// Each test uses its own random model name and day, so tests sharing the
/// database never touch each other's counters.
func freshModel() -> String { "model-\(UUID().uuidString.prefix(8))" }
func freshDay() -> ProviderDay { ProviderDay(key: "test-\(UUID().uuidString.prefix(8))") }

@Suite("Postgres budget store")
struct BudgetStoreTests {
    func store() async throws -> PostgresBudgetStore {
        PostgresBudgetStore(database: try await TestDatabase.get())
    }

    /// The same calls through Brain's reference store and ours must give the
    /// same answers, including which limit refused.
    @Test func behavesExactlyLikeBrainsInMemoryStore() async throws {
        let postgres = try await store()
        let memory = InMemoryBudgetStore()
        let model = freshModel()
        let day = freshDay()
        let alice = "alice-\(UUID())"
        let bob = "bob-\(UUID())"
        let script: [(user: String?, modelLimit: Int?, userLimit: Int?)] =
            Array(repeating: (alice, 10, 3), count: 5)  // alice hits her share at 3
            + Array(repeating: (bob, 10, 3), count: 3)  // bob still gets his 3
            + Array(repeating: (nil, 10, nil), count: 5)  // no user: model limit only
            + [(alice, nil, nil), (bob, 10, 100)]  // model at 10: refused

        for (i, call) in script.enumerated() {
            let expected = await memory.reserve(
                model: model, user: call.user, day: day,
                modelDailyLimit: call.modelLimit, userDailyLimit: call.userLimit)
            let actual = await postgres.reserve(
                model: model, user: call.user, day: day,
                modelDailyLimit: call.modelLimit, userDailyLimit: call.userLimit)
            #expect(actual == expected, "call \(i): \(call)")
        }
        let memoryCount = await memory.dailyRequests(model: model, day: day)
        let postgresCount = await postgres.dailyRequests(model: model, day: day)
        #expect(postgresCount == memoryCount)
    }

    /// Brain measured that the obvious read-then-write let 40 concurrent
    /// callers past a limit of 5. This must allow exactly 5.
    @Test func concurrentCallersCannotOverspendTheModel() async throws {
        let postgres = try await store()
        let model = freshModel()
        let day = freshDay()
        let results = await withTaskGroup(of: BudgetReservation.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await postgres.reserve(
                        model: model, user: nil, day: day, modelDailyLimit: 5,
                        userDailyLimit: nil)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.filter { $0 == .reserved }.count == 5)
        #expect(await postgres.dailyRequests(model: model, day: day) == 5)
    }

    /// One user spread over several models at once still gets exactly their share.
    @Test func concurrentCallersCannotOverspendAUsersShare() async throws {
        let postgres = try await store()
        let models = (0..<4).map { _ in freshModel() }
        let day = freshDay()
        let user = "user-\(UUID())"
        let results = await withTaskGroup(of: BudgetReservation.self) { group in
            for i in 0..<40 {
                group.addTask {
                    await postgres.reserve(
                        model: models[i % 4], user: user, day: day, modelDailyLimit: 1000,
                        userDailyLimit: 7)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.filter { $0 == .reserved }.count == 7)
        var charged = 0
        for model in models { charged += await postgres.dailyRequests(model: model, day: day) }
        #expect(charged == 7, "a refused user call must not charge the model either")
    }

    @Test func countsSurviveARestart() async throws {
        let model = freshModel()
        let day = freshDay()
        let before = try await store()
        for _ in 0..<3 {
            _ = await before.reserve(
                model: model, user: nil, day: day, modelDailyLimit: 3, userDailyLimit: nil)
        }
        // A new store instance stands in for a restarted server.
        let after = try await store()
        #expect(await after.dailyRequests(model: model, day: day) == 3)
        let refused = await after.reserve(
            model: model, user: nil, day: day, modelDailyLimit: 3, userDailyLimit: nil)
        #expect(refused == .refused(.requestsPerDay(limit: 3)))
    }

    @Test func eachProviderDayIsSeparate() async throws {
        let postgres = try await store()
        let model = freshModel()
        let monday = freshDay()
        let tuesday = freshDay()
        _ = await postgres.reserve(
            model: model, user: nil, day: monday, modelDailyLimit: 1, userDailyLimit: nil)
        let next = await postgres.reserve(
            model: model, user: nil, day: tuesday, modelDailyLimit: 1, userDailyLimit: nil)
        #expect(next == .reserved)
    }

    /// The key the ledger will actually use, around a DST change: the day must
    /// follow Pacific local midnight, not a fixed -08:00.
    @Test func providerDayFollowsPacificMidnightAcrossDST() throws {
        let iso = ISO8601DateFormatter()
        // 2026-11-01 is the US DST end. 07:30Z is 00:30 PDT; 08:30Z is 00:30 PST... both Nov 1.
        let before = try #require(iso.date(from: "2026-11-01T06:59:00Z"))  // 23:59 PDT Oct 31
        let after = try #require(iso.date(from: "2026-11-01T07:00:00Z"))  // 00:00 PDT Nov 1
        #expect(ProviderDay.containing(before).key == "2026-10-31")
        #expect(ProviderDay.containing(after).key == "2026-11-01")
        // After the change, midnight is 08:00Z.
        let lateNov2 = try #require(iso.date(from: "2026-11-03T07:59:00Z"))  // 23:59 PST Nov 2
        #expect(ProviderDay.containing(lateNov2).key == "2026-11-02")
    }
}
