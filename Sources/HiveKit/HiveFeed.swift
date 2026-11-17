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
    public struct Repo: Decodable, Equatable, Sendable {
        public var repo: String
        public var score: Int
    }
    public var method: Int
    public var score: Int
    public var word: String
    public var capped: Bool
    public var topFixes: [Fix]
    public var repos: [Repo]?
}

/// HiveWorld (`hiveworld.json`): which projects need work next, and why (for HiveTempo). The HiveWorld app decodes
/// every field with its own model in HiveWorldKit.
public struct WorldSummary: Decodable, Equatable, Sendable {
    public struct Project: Decodable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var need: Double?
        public var reason: String?
        public var paused: Bool
    }
    public var schemaVersion: Int
    /// Project ids, most in need first; paused and finished projects never appear.
    public var pick: [String]
    public var projects: [Project]
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
    /// Every sale from `income/ledger.csv`; nil in feeds written before the ledger existed.
    public var income: Income?

    public struct Income: Decodable, Equatable, Sendable {
        public struct Sale: Decodable, Equatable, Sendable {
            public var date: String; public var route: String; public var item: String; public var netUsd: Double
        }
        public var netUsd: Double
        public var monthNetUsd: Double
        public var pendingUsd: Double
        public var sales: Int
        public var byRoute: [String: Double]?
        /// The calendar month (YYYY-MM) `monthByRoute` covers; with `goalUsd`, added 2026-11-17.
        public var month: String?
        public var monthByRoute: [String: Double]?
        public var goalUsd: Double?
        public var lastSale: Sale?
        /// Deposits on their way (gross minus fees); added 2026-11-17 (Hive build order #2).
        public var payouts: Payouts?
    }

    public struct Payouts: Decodable, Equatable, Sendable {
        public struct Due: Decodable, Equatable, Sendable { public var date: String; public var usd: Double }
        public struct Late: Decodable, Equatable, Sendable { public var date: String; public var route: String; public var usd: Double }
        /// The earliest payout date still ahead, and what lands then.
        public var next: Due?
        public var waitingUsd: Double
        public var paidUsd: Double
        /// Pending sales more than 7 days past their payout date: no deposit recorded, check the platform.
        public var overdue: [Late]
        public var overdueUsd: Double
    }
}

/// Rule 15 at a glance: the best-earning route this month against the $100 goal (no new route starts before it).
public struct IncomeGoal: Equatable, Sendable {
    public var month: String
    public var monthNet: Double
    public var goal: Double
    public var bestRoute: String?
    public var best: Double
    public var met: Bool { best >= goal }
    /// 0...1, how far the best route is toward the goal.
    public var progress: Double { goal > 0 ? min(1, max(0, best / goal)) : 0 }
    public var left: Double { max(0, goal - best) }

    /// nil when the feed predates the monthly fields.
    public init?(_ business: BusinessSummary) {
        guard let income = business.income, let month = income.month, let byRoute = income.monthByRoute else { return nil }
        let top = byRoute.max { ($0.value, $1.key) < ($1.value, $0.key) }
        self.month = month
        self.monthNet = income.monthNetUsd
        self.goal = income.goalUsd ?? 100
        self.bestRoute = (top?.value ?? 0) > 0 ? top?.key : nil
        self.best = max(0, top?.value ?? 0)
    }
}

/// `releases.json`: the newest TestFlight upload of any Hive app, from `release-evidence/<build>/evidence.json`.
public struct ReleasesSummary: Decodable, Equatable, Sendable {
    public var app: String
    public var version: String
    public var build: String
    public var commit: String
    public var at: Date
    public var ready: Bool
    public var override: String?
    public var testsPassed: Int?
    public var screens: Int?
    public var underLoad: Bool?
}

/// `ideas.json`: ideas put to Noah in the last 14 days by the weekly idea generator.
public struct IdeasSummary: Decodable, Equatable, Sendable {
    public struct Idea: Decodable, Equatable, Sendable {
        public var askedOn: String
        public var n: Int
        public var kind: String
        public var title: String
        public var whyNow: String
        public var reuses: String?
        public var size: String
        public var ais: [String]?
    }
    public var ideas: [Idea]
}

/// Reads one app's feed file with the signed-in user's token (read-only, like every Hive app).
public struct HiveFeedReader: Sendable {
    /// The raw `<app>.json` bytes, or nil when the file doesn't exist yet.
    public typealias Fetch = @Sendable (_ app: String) async throws -> Data?
    let fetch: Fetch

    public init(client: GitHubClient, repo: String = "ndabney562/hivemind", branch: String = "hive") {
        self.fetch = { app in
            guard let data = try await client.rest("/repos/\(repo)/contents/\(app).json?ref=\(branch)", missing: [404]) else {
                return nil
            }
            let wrapped = try JSONDecoder().decode(Contents.self, from: data)
            guard let file = Data(base64Encoded: wrapped.content, options: .ignoreUnknownCharacters) else {
                throw FetchError.github(status: 200, message: "not base64")
            }
            return file
        }
    }

    /// Any other source of the feed files, e.g. HiveMind's iPhone asking its Mac hub (it holds no GitHub token).
    public init(fetch: @escaping Fetch) { self.fetch = fetch }

    /// nil when the file (or the branch) doesn't exist yet, or its schema is unknown.
    public func read<S: Decodable & Sendable>(_ app: String, as type: S.Type) async throws -> HiveFeedEnvelope<S>? {
        guard let file = try await fetch(app) else { return nil }
        return try HiveFeed.decode(file, as: type)
    }
}
