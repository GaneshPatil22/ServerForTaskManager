import API
import BrainCore
import Foundation

/// The rules the spec states but swift-openapi-generator 1.14.4 does not
/// enforce (`pattern`, `minLength`, `maxLength`, `minimum`, `maximum`).
/// Every one is checked here, and each has a test.
enum Validation {
    static let maxCaptureLength = 20_000
    static let maxTitleLength = 500
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
