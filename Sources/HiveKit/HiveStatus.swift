import Foundation

/// The Hive apps that publish to the feed, in menu order (docs/superpowers/specs/2026-11-09-hive-switcher-design.md).
/// HiveRounds is not one: it runs on the doctor's phone and never links to Noah's data at runtime.
public enum HiveApp: String, CaseIterable, Sendable {
    case mind, score, tempo

    /// The feed file's name (`<feedName>.json`).
    public var feedName: String {
        switch self {
        case .mind: "hivemind"
        case .score: "health-score"
        case .tempo: "hive-tempo"
        }
    }

    public var name: String {
        switch self {
        case .mind: "HiveMind"
        case .score: "HiveScore"
        case .tempo: "HiveTempo"
        }
    }

    /// Opens the app (each Hive app registers this scheme).
    public var url: URL { URL(string: "\(name.lowercased())://")! }
}

/// One row of the menu's "Hive apps" section: a sibling app and its status in a few words.
public struct HiveStatus: Equatable, Sendable {
    public var app: HiveApp
    public var line: String
    public var written: Date?
    public var stale: Bool

    public init(app: HiveApp, line: String, written: Date?, stale: Bool) {
        self.app = app
        self.line = line
        self.written = written
        self.stale = stale
    }

    /// What the row shows: the status, or when it was last updated once it is stale.
    public func shown(timeZone: TimeZone = .current) -> String {
        guard stale, let written else { return line }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return "not updated since " + f.string(from: written).lowercased()
    }

    static let none = "No status yet"

    public static func line(_ s: ScoreSummary) -> String {
        s.capped ? "\(s.score) · capped by a safety problem" : "\(s.score) · \(s.word)"
    }

    public static func line(_ s: TempoSummary) -> String {
        if s.total == 0 { return "Nothing planned today" }
        if s.state == "finished" || s.done >= s.total { return "All \(s.total) done" }
        var out = "\(s.done) of \(s.total) done"
        if let next = s.next { out += " · next: " + next.title + (next.at.flatMap(twelveHour).map { " " + $0 } ?? "") }
        return out
    }

    public static func line(_ s: HiveMindSummary) -> String {
        var parts: [String] = []
        if let low = s.quota.filter({ $0.leftPct != nil }).min(by: { $0.leftPct! < $1.leftPct! }) {
            parts.append("\(low.ai.prefix(1).uppercased() + low.ai.dropFirst()) \(low.leftPct!)% left")
        }
        switch s.alerts.count {
        case 0: if parts.isEmpty { parts.append("No alerts") }
        case 1: parts.append("1 alert")
        case let n: parts.append("\(n) alerts")
        }
        return parts.joined(separator: " · ")
    }

    /// "16:00" → "4:00 pm"; nil for anything else.
    static func twelveHour(_ hhmm: String) -> String? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return "\(h % 12 == 0 ? 12 : h % 12):" + (m < 10 ? "0" : "") + "\(m) " + (h < 12 ? "am" : "pm")
    }
}

extension HiveFeedReader {
    /// Every Hive app's status except `app` (the one asking), in `HiveApp` order. A file that is missing or fails to
    /// read gives "No status yet" for that row only.
    public func statuses(except app: HiveApp?, now: Date = Date()) async -> [HiveStatus] {
        let wanted = HiveApp.allCases.filter { $0 != app }
        return await withTaskGroup(of: (Int, HiveStatus).self) { group in
            for (i, a) in wanted.enumerated() {
                group.addTask { (i, await status(a, now: now)) }
            }
            var out = [HiveStatus?](repeating: nil, count: wanted.count)
            for await (i, s) in group { out[i] = s }
            return out.map { $0! }
        }
    }

    func status(_ app: HiveApp, now: Date) async -> HiveStatus {
        func row<S: Decodable & Sendable>(_ type: S.Type, _ line: (S) -> String) async -> HiveStatus {
            guard let feed = try? await read(app.feedName, as: type) else {
                return HiveStatus(app: app, line: HiveStatus.none, written: nil, stale: false)
            }
            return HiveStatus(app: app, line: line(feed.summary), written: feed.writtenAt, stale: feed.isStale(now: now))
        }
        switch app {
        case .mind: return await row(HiveMindSummary.self, HiveStatus.line)
        case .score: return await row(ScoreSummary.self, HiveStatus.line)
        case .tempo: return await row(TempoSummary.self, HiveStatus.line)
        }
    }
}
