import Foundation
import Jobs

/// Enrich one capture. Pushed when a capture is created, and by the sweeper
/// for any capture whose job was lost.
public struct EnrichCapture: JobParameters {
    public static let jobName = "enrich-capture"
    public let user: UUID
    public let capture: String

    public init(user: UUID, capture: String) {
        self.user = user
        self.capture = capture
    }
}

/// Find captures whose enrichment never finished, and queue them again.
public struct SweepCaptures: JobParameters {
    public static let jobName = "sweep-captures"
    public init() {}
}
