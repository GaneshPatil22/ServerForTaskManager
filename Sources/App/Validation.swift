import API
import BrainCore
import Foundation
import Storage

/// The rules the spec states but swift-openapi-generator 1.14.4 does not
/// enforce (`pattern`, `minLength`, `maxLength`, `minimum`, `maximum`).
/// Every one is checked here, and each has a test.
enum Validation {
    static let maxCaptureLength = 20_000
    static let maxTitleLength = 500
    /// Longer than any option Brain offers; checked again against the stored set.
    static let maxOptionLength = 100
    static let defaultLimit = 100
    static let maxLimit = 500

    struct Failure: Error, Equatable {
        let code: String
        let message: String
    }

    static func ulid(_ raw: String, field: String) throws(Failure) -> ULID {
        guard let id = ULID(raw), id.rawValue == raw else {
            throw Failure(code: "invalid_id", message: "\(field) must be a ULID")
        }
        return id
    }

    static func optionalULID(_ raw: String?, field: String) throws(Failure) -> ULID? {
        guard let raw else { return nil }
        return try ulid(raw, field: field)
    }

    static func limit(_ raw: Int?) throws(Failure) -> Int {
        let value = raw ?? defaultLimit
        guard (1...maxLimit).contains(value) else {
            throw Failure(code: "invalid_limit", message: "limit must be 1 to \(maxLimit)")
        }
        return value
    }

    /// Length in Unicode scalars, which is how JSON Schema counts characters.
    static func text(_ value: String, field: String, max: Int) throws(Failure) -> String {
        let length = value.unicodeScalars.count
        guard length >= 1 else {
            throw Failure(code: "empty_\(field)", message: "\(field) must not be empty")
        }
        guard length <= max else {
            throw Failure(code: "\(field)_too_long", message: "\(field) is over \(max) characters")
        }
        return value
    }

    static func timezone(_ name: String) throws(Failure) -> String {
        guard TimeZone(identifier: name) != nil else {
            throw Failure(code: "invalid_timezone", message: "not an IANA timezone name")
        }
        return name
    }
}

// MARK: - Planner (P4)

extension Validation {
    static let maxCommitmentTitleLength = 200
    static let maxNoteLength = 200
    static let maxJournalLength = 2_000
    /// A quarter, with a day to spare. Expansion is cheap; this bounds the
    /// response, not the work.
    static let maxRangeDays = 92

    static func day(_ raw: String, field: String) throws(Failure) -> CalendarDay {
        guard let day = CalendarDay(storedValue: raw) else {
            throw Failure(code: "invalid_day", message: "\(field) must be a real day, YYYY-MM-DD")
        }
        return day
    }

    static func optionalDay(_ raw: String?, field: String) throws(Failure) -> CalendarDay? {
        guard let raw else { return nil }
        return try day(raw, field: field)
    }

    static func period(_ raw: String, field: String) throws(Failure) -> GoalPeriod {
        guard let period = GoalPeriod(storedValue: raw) else {
            throw Failure(
                code: "invalid_period", message: "\(field) must be like 2026-11 or 2026-Q4")
        }
        return period
    }

    static func optionalPeriod(_ raw: String?, field: String) throws(Failure) -> GoalPeriod? {
        guard let raw else { return nil }
        return try period(raw, field: field)
    }

    static func range(from: String, through: String) throws(Failure) -> (
        from: CalendarDay, through: CalendarDay
    ) {
        let start = try day(from, field: "from")
        let end = try day(through, field: "through")
        guard start <= end else {
            throw Failure(code: "invalid_range", message: "from must not be after through")
        }
        guard daysBetween(start, end) < maxRangeDays else {
            throw Failure(code: "invalid_range", message: "at most \(maxRangeDays) days at a time")
        }
        return (start, end)
    }

    static func daysBetween(_ a: CalendarDay, _ b: CalendarDay) -> Int {
        let utc = TimeZone(identifier: "UTC")!
        return Int(
            (b.start(in: utc).timeIntervalSince(a.start(in: utc)) / 86_400).rounded())
    }

    static func minutes(_ value: Int) throws(Failure) -> Int {
        guard (0...1440).contains(value) else {
            throw Failure(code: "invalid_minutes", message: "minutes must be 0 to 1440")
        }
        return value
    }

    /// An optional free-text field: empty means none.
    static func note(_ value: String?) throws(Failure) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return try text(value, field: "note", max: maxNoteLength)
    }

    /// Exactly the fields the rule's shape uses, each in range.
    static func rule(_ rule: Components.Schemas.Rule) throws(Failure) -> RecurrenceRule {
        let bad = Failure(
            code: "invalid_rule",
            message: "\(rule.kind.rawValue) takes "
                + [
                    .daily: "no other fields", .weeklyOn: "weekday",
                    .monthlyOnDay: "day (1-31)", .monthlyOnNthWeekday: "n (1-5) and weekday",
                    .quarterlyOnNthWeekday: "n (1-5) and weekday",
                ][rule.kind, default: "?"] + ", and nothing else")
        let weekday = rule.weekday.map(BrainCore.Weekday.init)
        switch (rule.kind, weekday, rule.day, rule.n) {
        case (.daily, nil, nil, nil):
            return .daily
        case (.weeklyOn, let w?, nil, nil):
            return .weeklyOn(w)
        case (.monthlyOnDay, nil, let d?, nil) where (1...31).contains(d):
            return .monthlyOnDay(d)
        case (.monthlyOnNthWeekday, let w?, nil, let n?) where (1...5).contains(n):
            return .monthlyOnNthWeekday(n: n, weekday: w)
        case (.quarterlyOnNthWeekday, let w?, nil, let n?) where (1...5).contains(n):
            return .quarterlyOnNthWeekday(n: n, weekday: w)
        default:
            throw bad
        }
    }
}
