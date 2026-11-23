import Foundation
import OpenAPIRuntime

/// Dates on the wire: accepted with or without fractional seconds, always
/// sent with milliseconds.
///
/// The runtime's default (`.iso8601`) rejects fractional seconds, but every
/// browser sends them: `new Date().toISOString()` gives `…T10:00:00.123Z`.
/// The first real end-to-end run with the website refused every capture with
/// 400 because of this. Sending milliseconds back keeps what the client sent
/// intact, instead of silently truncating it.
struct BrowserFriendlyDates: DateTranscoder {
    /// Whole milliseconds, computed as an integer and written out by hand.
    /// Postgres keeps microseconds and `Date` is a `Double`, so a stored
    /// `.123` is really `.12299999…`, and Foundation's formatter truncates
    /// fractions rather than rounding them: the client would get `.122` back.
    func encode(_ date: Date) throws -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (seconds, remainder) = millis.quotientAndRemainder(dividingBy: 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds))
            .formatted(Date.ISO8601FormatStyle())  // "…T11:06:39Z"
        let fraction = String(format: ".%03lld", remainder)
        return whole.dropLast() + fraction + "Z"
    }

    func decode(_ string: String) throws -> Date {
        if let date = try? Date(
            string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        {
            return date
        }
        return try Date(string, strategy: Date.ISO8601FormatStyle())
    }
}
