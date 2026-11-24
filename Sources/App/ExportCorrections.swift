import ArgumentParser
import Foundation
import Hummingbird
import Logging
import Storage

/// Writes every correction as JSON lines to standard output, for analysis.
///
///     docker exec brain-server ./brain-server export-corrections > corrections.jsonl
///
/// Users appear only as a salted hash (`CORRECTIONS_EXPORT_SALT`); item
/// titles and capture text are included (DECISIONS, 24 Nov). Logs go to
/// standard error so the output stays clean JSON lines.
struct ExportCorrections: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export corrections as JSON lines, users pseudonymised.")

    @Option(help: "Only corrections on or after this day (YYYY-MM-DD, UTC).")
    var since: String?

    func run() async throws {
        let logger = Logger(label: "brain-export") { StreamLogHandler.standardError(label: $0) }
        guard let salt = Environment().get("CORRECTIONS_EXPORT_SALT"), salt.count >= 16 else {
            throw ExportError(
                "CORRECTIONS_EXPORT_SALT must be set (16+ characters): it hides who is who")
        }
        let sinceDate: Date? = try since.map { day in
            guard
                let date = try? Date(
                    "\(day)T00:00:00Z", strategy: Date.ISO8601FormatStyle())
            else { throw ExportError("--since must be YYYY-MM-DD") }
            return date
        }
        let database = Database(configuration: try .fromEnvironment(), logger: logger)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let count = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                await database.run()
                return nil
            }
            group.addTask {
                let rows = try await database.exportCorrections(since: sinceDate, salt: salt)
                for row in rows {
                    FileHandle.standardOutput.write(try encoder.encode(row))
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                return rows.count
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let count = result { return count }
            }
            return 0
        }
        logger.info("exported corrections", metadata: ["count": "\(count)"])
    }
}

/// Not `ValidationError`, which also prints the usage text: these are
/// configuration problems, not mistyped arguments.
struct ExportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
