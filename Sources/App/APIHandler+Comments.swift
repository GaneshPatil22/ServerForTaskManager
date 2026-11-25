import API
import BrainCore
import Foundation
import Storage

/// Comments and count goals (M0007). The user's own records: nothing here is
/// passed to Brain or to a model.
extension APIHandler {
    // MARK: - Comments

    func listComments(_ input: Operations.ListComments.Input) async throws
        -> Operations.ListComments.Output
    {
        try await run(
            {
                let q = input.query
                let target = try check { () throws(Validation.Failure) in
                    try Validation.commentTarget(
                        item: q.itemId, goal: q.goalId, commitment: q.commitmentId)
                }
                let comments = try await store().comments(on: target)
                return .ok(.init(body: .json(.init(comments: comments.map { .init($0) }))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func createComment(_ input: Operations.CreateComment.Input) async throws
        -> Operations.CreateComment.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let now = clock()
                let comment = try check { () throws(Validation.Failure) in
                    StoredComment(
                        id: try Validation.ulid(body.id, field: "id"),
                        target: try Validation.commentTarget(
                            item: body.itemId, goal: body.goalId, commitment: body.commitmentId),
                        body: try Validation.text(
                            body.body, field: "body", max: Validation.maxCommentLength),
                        createdAt: now, updatedAt: now)
                }
                let result: (comment: StoredComment, created: Bool)
                do {
                    result = try await store().insertComment(comment)
                } catch CountRefusal.unknownTarget {
                    throw Stop.notFound("item, goal or commitment")
                }
                let json = Components.Schemas.Comment(result.comment)
                return result.created
                    ? .created(.init(body: .json(json))) : .ok(.init(body: .json(json)))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func updateComment(_ input: Operations.UpdateComment.Input) async throws
        -> Operations.UpdateComment.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (id, text) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(input.path.id, field: "id"),
                        try Validation.text(
                            body.body, field: "body", max: Validation.maxCommentLength)
                    )
                }
                guard let comment = try await store().editComment(id, body: text, at: clock())
                else { throw Stop.notFound("comment") }
                return .ok(.init(body: .json(.init(comment))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func deleteComment(_ input: Operations.DeleteComment.Input) async throws
        -> Operations.DeleteComment.Output
    {
        try await run(
            {
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                guard try await store().deleteComment(id) else { throw Stop.notFound("comment") }
                return .noContent(.init())
            }, problem: { .default(statusCode: $0, $1) })
    }

    // MARK: - Count goals

    func listGoalMarks(_ input: Operations.ListGoalMarks.Input) async throws
        -> Operations.ListGoalMarks.Output
    {
        try await run(
            {
                let id = try check { () throws(Validation.Failure) in
                    try Validation.ulid(input.path.id, field: "id")
                }
                let store = try await store()
                guard try await store.goal(id) != nil else { throw Stop.notFound("goal") }
                let marks = try await store.marks(of: id)
                return .ok(.init(body: .json(.init(marks: marks.map { .init($0) }))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func addGoalMark(_ input: Operations.AddGoalMark.Input) async throws
        -> Operations.AddGoalMark.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let (goal, id, day, note) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(input.path.id, field: "id"),
                        try Validation.ulid(body.id, field: "markId"),
                        try Validation.optionalDay(body.day, field: "day"),
                        try body.note.map { note throws(Validation.Failure) in
                            try Validation.text(
                                note, field: "note", max: Validation.maxMarkNoteLength)
                        }
                    )
                }
                let store = try await store()
                let (today, _) = try await today(store)
                let markDay = day ?? today
                guard Validation.daysBetween(today, markDay) <= 0 else {
                    throw Stop.badRequest("in_future", "a circle is filled on a day that has come")
                }
                let now = clock()
                let result: (mark: GoalMark, created: Bool)
                do {
                    result = try await store.addMark(
                        GoalMark(
                            id: id, goalId: goal, day: markDay, note: note, createdAt: now,
                            updatedAt: now))
                } catch let refusal as CountRefusal {
                    throw Stop(refusal)
                }
                let json = Components.Schemas.GoalMark(result.mark)
                return result.created
                    ? .created(.init(body: .json(json))) : .ok(.init(body: .json(json)))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func updateGoalMark(_ input: Operations.UpdateGoalMark.Input) async throws
        -> Operations.UpdateGoalMark.Output
    {
        try await run(
            {
                let body =
                    switch input.body {
                    case .json(let body): body
                    }
                let clearNote = (body.clear ?? []).contains(.note)
                let (goal, id, note) = try check { () throws(Validation.Failure) in
                    if clearNote && body.note != nil {
                        throw Validation.Failure(
                            code: "conflicting_clear", message: "a field is both sent and cleared")
                    }
                    return (
                        try Validation.ulid(input.path.id, field: "id"),
                        try Validation.ulid(input.path.markId, field: "markId"),
                        try body.note.map { note throws(Validation.Failure) in
                            try Validation.text(
                                note, field: "note", max: Validation.maxMarkNoteLength)
                        }
                    )
                }
                let store = try await store()
                guard note != nil || clearNote else {
                    // Nothing to change: answer with the mark as it is.
                    guard let mark = try await store.marks(of: goal).first(where: { $0.id == id })
                    else { throw Stop.notFound("circle") }
                    return .ok(.init(body: .json(.init(mark))))
                }
                guard
                    let mark = try await store.editMark(
                        id, goal: goal, note: clearNote ? nil : note, at: clock())
                else { throw Stop.notFound("circle") }
                return .ok(.init(body: .json(.init(mark))))
            }, problem: { .default(statusCode: $0, $1) })
    }

    func deleteGoalMark(_ input: Operations.DeleteGoalMark.Input) async throws
        -> Operations.DeleteGoalMark.Output
    {
        try await run(
            {
                let (goal, id) = try check { () throws(Validation.Failure) in
                    (
                        try Validation.ulid(input.path.id, field: "id"),
                        try Validation.ulid(input.path.markId, field: "markId")
                    )
                }
                guard try await store().deleteMark(id, goal: goal) else {
                    throw Stop.notFound("circle")
                }
                return .noContent(.init())
            }, problem: { .default(statusCode: $0, $1) })
    }
}

extension APIHandler.Stop {
    init(_ refusal: CountRefusal) {
        switch refusal {
        case .unknownTarget:
            self = .notFound("goal")
        case .notACountGoal:
            self = .badRequest(
                "not_a_count_goal", "this goal has no target count, so no circles to fill")
        case .targetReached:
            self.init(
                status: 409, code: "target_reached",
                message: "every circle is filled; raise the target to add more")
        case .targetBelowDone(let done):
            self = .badRequest(
                "target_below_done",
                "\(done) circle\(done == 1 ? " is" : "s are") filled; empty some first")
        }
    }
}
