import Foundation

/// The Hive feed (docs/hive-feed.md): each Hive app's status, one small JSON file per app on the `hive` branch of
/// ndabney562/hivemind. Only the Mac writes it (`hivemind feed publish`); apps read it here.
public enum HiveFeed {
    public static let schema = 1

    /// The envelope, or nil when its schema is not one this reader knows. Unknown fields are ignored.
    public static func decode<S: Decodable & Sendable>(_ data: Data, as: S.Type) throws -> HiveFeedEnvelope<S>? {
        guard try decoder.decode(Probe.self, from: data).schema == schema else { return nil }
        return try decoder.decode(HiveFeedEnvelope<S>.self, from: data)
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private struct Probe: Decodable { var schema: Int }
private struct Contents: Decodable { var content: String }

public struct HiveFeedEnvelope<Summary: Decodable & Sendable>: Decodable, Sendable {
    public struct Detail: Decodable, Equatable, Sendable {
        public var repo: String
        public var branch: String
        public var path: String
    }

    public var schema: Int
    public var app: String
    public var writtenAt: Date
    public var staleAfterMinutes: Int
    public var detail: Detail?
    public var summary: Summary

    /// Past `written_at + stale_after_minutes`: show it as old, never as current.
    public func isStale(now: Date) -> Bool {
        now > writtenAt.addingTimeInterval(TimeInterval(staleAfterMinutes * 60))
    }
}

/// `hivemind.json`: quota left per AI, open alerts, HiveMind's current improvement item.
public struct HiveMindSummary: Decodable, Equatable, Sendable {
    public struct Quota: Decodable, Equatable, Sendable { public var ai: String; public var leftPct: Int?; public var readAt: Date? }
    public struct Alert: Decodable, Equatable, Sendable { public var kind: String; public var text: String; public var at: Date? }
    public var quota: [Quota]
    public var alerts: [Alert]
    public var now: String?
}

/// `hive-tempo.json`: today's plan. `state` is one of HiveTempo's widget phases (unavailable, empty, scheduled,
/// inProgress, finished, outOfTime).
public struct TempoSummary: Decodable, Equatable, Sendable {
    public struct Task: Decodable, Equatable, Sendable { public var title: String; public var until: String?; public var at: String? }
    public var date: String
    public var state: String
    public var done: Int
    public var total: Int
    public var current: Task?
    public var next: Task?
}

/// `health-score.json`: the HiveScore number and its top fixes, scored on the Mac with the app's own code.
public struct ScoreSummary: Decodable, Equatable, Sendable {
    public struct Fix: Decodable, Equatable, Sendable {
        public var id: String
        public var repo: String
        public var title: String
        public var points: Double
    }
    public var method: Int
    public var score: Int
    public var word: String
    public var capped: Bool
    public var topFixes: [Fix]
}

/// The AI business (`ai-business-db.json`): the 90-day income challenge and each earning route.
public struct BusinessSummary: Decodable, Equatable, Sendable {
    public struct Route: Decodable, Equatable, Sendable { public var name: String; public var status: String; public var earnedUsd: Double? }
    public struct Checkpoint: Decodable, Equatable, Sendable { public var date: String; public var title: String }
    public var day: Int
    public var daysTotal: Int
    public var ends: String
    public var earnedUsd: Double
    public var routes: [Route]
    public var nextCheckpoint: Checkpoint?
}

/// Reads one app's feed file with the signed-in user's token (read-only, like every Hive app).
public struct HiveFeedReader: Sendable {
    let client: GitHubClient
    let repo: String
    let branch: String

    public init(client: GitHubClient, repo: String = "ndabney562/hivemind", branch: String = "hive") {
        self.client = client
        self.repo = repo
        self.branch = branch
    }

    /// nil when the file (or the branch) doesn't exist yet, or its schema is unknown.
    public func read<S: Decodable & Sendable>(_ app: String, as type: S.Type) async throws -> HiveFeedEnvelope<S>? {
        guard let data = try await client.rest("/repos/\(repo)/contents/\(app).json?ref=\(branch)", missing: [404]) else {
            return nil
        }
        let wrapped = try JSONDecoder().decode(Contents.self, from: data)
        guard let file = Data(base64Encoded: wrapped.content, options: .ignoreUnknownCharacters) else {
            throw FetchError.github(status: 200, message: "not base64")
        }
        return try HiveFeed.decode(file, as: type)
    }
}
