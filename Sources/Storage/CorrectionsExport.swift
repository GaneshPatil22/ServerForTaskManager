import BrainCore
import Foundation
import PostgresNIO

/// One correction, as it leaves the database for analysis: the user's
/// decision plus enough context to read it without the database.
///
/// **This carries user content** (item titles, the capture's text). Ganesh
/// chose that on 24 Nov: a `bigTask` swap is two ids, and ids teach nothing.
/// The T&C has to say corrections may be exported to improve Brain. The
/// user's id never leaves: `user` is a salted hash, stable across exports
/// that use the same salt, so one person's corrections can still be grouped.
public struct ExportedCorrection: Codable, Sendable, Equatable {
    public struct Target: Codable, Sendable, Equatable {
        /// `item`, `edge`, `goal`, or `unknown` if the target is gone.
        public var kind: String
        public var title: String?
        /// The capture the item came from, if it came from one.
        public var captureText: String?
        /// For an edge: its kind and the titles at either end.
        public var edgeKind: String?
        public var fromTitle: String?
        public var toTitle: String?
    }

    public var user: String
    public var id: String
    public var createdAt: Date
    public var field: String
    /// The tier whose decision the user corrected.
    public var tier: String
    public var before: String?
    public var after: String?
    /// When `before` / `after` are ids of the user's items or goals (a
    /// `bigTask` swap, a `goalId` change), their titles.
    public var beforeTitle: String?
    public var afterTitle: String?
    public var target: Target
}

extension Database {
    /// Every correction since `since`, oldest first, across all users.
    ///
    /// Deployment-wide, like the sweeper's queries, and for the operator only:
    /// it is reachable from the `export-corrections` command, never from HTTP.
    public func exportCorrections(since: Date?, salt: String) async throws
        -> [ExportedCorrection]
    {
        precondition(!salt.isEmpty, "an empty salt makes the pseudonym reversible")
        let rows = try await client.query(
            """
            SELECT
                left(encode(sha256(convert_to(\(salt) || c.user_id::text, 'UTF8')), 'hex'), 16)
                    AS pseudonym,
                c.id, c.created_at, c.field, c.tier, c.before_value, c.after_value,
                coalesce(bi.title, bg.title) AS before_title,
                coalesce(ai.title, ag.title) AS after_title,
                CASE WHEN ti.id IS NOT NULL THEN 'item'
                     WHEN te.id IS NOT NULL THEN 'edge'
                     WHEN tg.id IS NOT NULL THEN 'goal'
                     ELSE 'unknown' END AS target_kind,
                coalesce(ti.title, tg.title) AS target_title,
                tc.raw_text AS capture_text,
                te.kind AS edge_kind,
                ef.title AS from_title,
                coalesce(eti.title, etg.title) AS to_title
            FROM corrections c
            LEFT JOIN items ti ON ti.user_id = c.user_id AND ti.id = c.target_id
            LEFT JOIN captures tc ON tc.user_id = c.user_id AND tc.id = ti.capture_id
            LEFT JOIN goals tg ON tg.user_id = c.user_id AND tg.id = c.target_id
            LEFT JOIN edges te ON te.user_id = c.user_id AND te.id = c.target_id
            LEFT JOIN items ef ON ef.user_id = c.user_id AND ef.id = te.from_item_id
            LEFT JOIN items eti ON eti.user_id = c.user_id AND eti.id = te.to_item_id
            LEFT JOIN goals etg ON etg.user_id = c.user_id AND etg.id = te.to_goal_id
            LEFT JOIN items bi ON bi.user_id = c.user_id AND bi.id::text = c.before_value
            LEFT JOIN goals bg ON bg.user_id = c.user_id AND bg.id::text = c.before_value
            LEFT JOIN items ai ON ai.user_id = c.user_id AND ai.id::text = c.after_value
            LEFT JOIN goals ag ON ag.user_id = c.user_id AND ag.id::text = c.after_value
            WHERE (\(since)::timestamptz IS NULL OR c.created_at >= \(since)::timestamptz)
            ORDER BY c.created_at, c.id
            """, logger: logger)
        var result: [ExportedCorrection] = []
        for try await row in rows {
            let r = RowReader(row: row.makeRandomAccess(), table: "corrections")
            result.append(
                ExportedCorrection(
                    user: try r.value("pseudonym"), id: try r.value("id"),
                    createdAt: try r.value("created_at"), field: try r.value("field"),
                    tier: try r.value("tier"),
                    before: try r.value("before_value", as: String?.self),
                    after: try r.value("after_value", as: String?.self),
                    beforeTitle: try r.value("before_title", as: String?.self),
                    afterTitle: try r.value("after_title", as: String?.self),
                    target: .init(
                        kind: try r.value("target_kind"),
                        title: try r.value("target_title", as: String?.self),
                        captureText: try r.value("capture_text", as: String?.self),
                        edgeKind: try r.value("edge_kind", as: String?.self),
                        fromTitle: try r.value("from_title", as: String?.self),
                        toTitle: try r.value("to_title", as: String?.self))))
        }
        return result
    }
}
