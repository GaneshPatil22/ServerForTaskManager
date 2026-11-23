import BrainCore
import Foundation
import Testing

@testable import Storage

@Suite("Links in storage")
struct LinkStorageTests {
    /// Two opposite links made at the same moment, many times over: the user
    /// lock means exactly one of each pair survives, and no cycle is stored.
    @Test func simultaneousOppositeLinksNeverFormACycle() async throws {
        let store = try await TestDatabase.newUser()
        for _ in 0..<15 {
            let a = Item(id: newID(), title: "a", createdAt: fixedDate)
            let b = Item(id: newID(), title: "b", createdAt: fixedDate)
            try await store.insertItem(a)
            try await store.insertItem(b)
            let results = await withTaskGroup(of: Bool.self) { group in
                for (from, to) in [(a.id, b.id), (b.id, a.id)] {
                    group.addTask {
                        let edge = Edge(
                            id: newID(), from: from, to: to, kind: .blocks, source: .user,
                            confirmed: true)
                        return (try? await store.createUserLink(edge)) != nil
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(results.filter { $0 }.count == 1)
        }
        // And the stored graph loads, which it would not with a cycle.
        _ = try await store.graph()
    }

    /// The worker's insert path must never bring a rejected link back.
    @Test func rejectedLinkIsNeverReSuggested() async throws {
        let store = try await TestDatabase.newUser()
        let a = Item(id: newID(), title: "a", createdAt: fixedDate)
        let b = Item(id: newID(), title: "b", createdAt: fixedDate)
        try await store.insertItem(a)
        try await store.insertItem(b)
        let suggestion = Edge(id: newID(), from: a.id, to: b.id, kind: .blocks, source: .t2Model)
        try await store.insertEdge(suggestion)
        #expect(try await store.rejectLink(suggestion.id, correction: newID(), at: fixedDate))

        let again = Edge(id: newID(), from: a.id, to: b.id, kind: .blocks, source: .t2Model)
        let inserted = try await store.insertEdge(
            again, on: try await TestDatabase.get().client, skipDuplicate: true)
        #expect(inserted == false)
        #expect(try await store.edges().isEmpty)
    }
}
