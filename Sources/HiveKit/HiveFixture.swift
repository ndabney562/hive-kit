import Foundation

/// Hive build order #9 (Fixture 57): fixed, fictional Hive feed files for every state an app must survive: normal,
/// empty, missing, stale, offline and malformed. An app started with `-hive-fixture <scenario>` reads these instead
/// of GitHub, so its UI test can screenshot each state; `HiveFixture.preview` lists what a reader gets in each one.
/// Same `now`, same bytes: nothing random, nothing from the network, no personal data (every name is made up).
public enum HiveFixture {
    public enum Scenario: String, CaseIterable, Sendable {
        /// Every file present, fresh, with sample data.
        case normal
        /// Every file present and fresh, with nothing in it yet (no tasks, no alerts, no sales).
        case empty
        /// No feed files at all (the Mac has never published).
        case missing
        /// The normal files, written long enough ago that readers must show them as old.
        case stale
        /// No connection: every read throws `FetchError.offline`.
        case offline
        /// Every file cut off mid-way, so it is not valid JSON.
        case malformed
    }

    /// `-hive-fixture stale` on an app's launch arguments (e.g. from its UI test).
    public static let launchArgument = "-hive-fixture"

    /// The scenario the app was launched with, or nil for real data. An unknown name is nil too.
    public static func scenario(arguments: [String] = ProcessInfo.processInfo.arguments) -> Scenario? {
        guard let i = arguments.firstIndex(of: launchArgument), i + 1 < arguments.count else { return nil }
        return Scenario(rawValue: arguments[i + 1])
    }

    /// The feed files there are fixtures for (`<app>.json` on the `hive` branch).
    public static var apps: [String] { normal.keys.sorted() }

    /// One feed file as the reader would fetch it: nil when it does not exist; throws `FetchError.offline` offline.
    /// `timeZone` is the reader's: `date` and `HH:MM` fields in the feed are local (hive-tempo writes its own day).
    public static func file(_ app: String, _ scenario: Scenario, now: Date, timeZone: TimeZone = .current) throws -> Data? {
        guard let normalText = normal[app], let emptyText = empty[app] else { return nil }
        switch scenario {
        case .missing: return nil
        case .offline: throw FetchError.offline
        case .normal: return Data(fill(normalText, app: app, now: now, writtenAgo: 10 * 60, timeZone: timeZone).utf8)
        case .empty: return Data(fill(emptyText, app: app, now: now, writtenAgo: 10 * 60, timeZone: timeZone).utf8)
        case .stale:
            // Twice its own stale window plus a day: old by any reader's measure.
            let window = TimeInterval(staleAfter[app, default: 60] * 60)
            return Data(fill(normalText, app: app, now: now, writtenAgo: 2 * window + 86_400, timeZone: timeZone).utf8)
        case .malformed:
            let whole = fill(normalText, app: app, now: now, writtenAgo: 10 * 60, timeZone: timeZone)
            return Data(whole.prefix(whole.count / 2).utf8)
        }
    }

    /// A feed reader that serves the scenario's files.
    public static func reader(_ scenario: Scenario, now: @escaping @Sendable () -> Date = Date.init,
                              timeZone: TimeZone = .current) -> HiveFeedReader {
        HiveFeedReader { app in try file(app, scenario, now: now(), timeZone: timeZone) }
    }

    /// What a reader gets from one file: shown, shown as old, nothing yet, offline or unreadable.
    public enum Outcome: String, Sendable {
        case shown, shownAsOld = "shown as old", noFile = "no file yet", offline, unreadable
    }

    public struct Row: Equatable, Sendable {
        public var app: String
        public var scenario: Scenario
        public var outcome: Outcome
    }

    /// Every app with a hive-kit summary type, in every scenario: what `HiveFeedReader.read` gives an app.
    public static func preview(now: Date, timeZone: TimeZone = .current) async -> [Row] {
        var rows: [Row] = []
        for scenario in Scenario.allCases {
            let reader = reader(scenario, now: { now }, timeZone: timeZone)
            for app in apps {
                rows.append(Row(app: app, scenario: scenario, outcome: await outcome(app, reader: reader, now: now)))
            }
        }
        return rows
    }

    static func outcome(_ app: String, reader: HiveFeedReader, now: Date) async -> Outcome {
        func classify<S: Decodable & Sendable>(_ type: S.Type) async -> Outcome {
            do {
                guard let feed = try await reader.read(app, as: type) else { return .noFile }
                return feed.isStale(now: now) ? .shownAsOld : .shown
            } catch FetchError.offline {
                return .offline
            } catch {
                return .unreadable
            }
        }
        switch app {
        case "hivemind": return await classify(HiveMindSummary.self)
        case "hive-tempo": return await classify(TempoSummary.self)
        case "health-score": return await classify(ScoreSummary.self)
        case "hiveworld": return await classify(WorldSummary.self)
        case "ai-business-db": return await classify(BusinessSummary.self)
        case "releases": return await classify(ReleasesSummary.self)
        case "ideas": return await classify(IdeasSummary.self)
        case "jobs": return await classify(JobsSummary.self)
        case "tools": return await classify(ToolsSummary.self)
        default: return await classify(AnySummary.self)
        }
    }

    /// For feeds whose summary type lives in an app (iphone: HiveScore's PhoneSummary).
    struct AnySummary: Decodable, Sendable {}

    // MARK: - The files

    /// `{{recent}}` (5 minutes before now, UTC), `{{today}}`, `{{day+N}}` (N days on), `{{month}}` (YYYY-MM) and
    /// `{{later}}` (an hour from now, HH:MM) in `timeZone` are filled in from `now`, so a fixed `now` and time zone
    /// give the same bytes every time.
    static func fill(_ text: String, app: String, now: Date, writtenAgo: TimeInterval, timeZone: TimeZone) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.locale = day.locale
        clock.timeZone = day.timeZone
        clock.dateFormat = "HH:mm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let month = DateFormatter()
        month.locale = day.locale
        month.timeZone = timeZone
        month.dateFormat = "yyyy-MM"
        // {{day+N}}: N days from today, so "this month", a payout next week and a renewal soon stay true for any now.
        var body = text
        while let r = body.range(of: #"\{\{day([+-]\d+)\}\}"#, options: .regularExpression) {
            let n = Int(body[r].dropFirst(5).dropLast(2)) ?? 0
            body.replaceSubrange(r, with: day.string(from: calendar.date(byAdding: .day, value: n, to: now) ?? now))
        }
        body = body
            .replacingOccurrences(of: "{{month}}", with: month.string(from: now))
            .replacingOccurrences(of: "{{recent}}", with: iso.string(from: now.addingTimeInterval(-300)))
            .replacingOccurrences(of: "{{today}}", with: day.string(from: now))
            .replacingOccurrences(of: "{{later}}", with: clock.string(from: now.addingTimeInterval(3600)))
        return """
        {"schema": 1, "app": "\(app)", "written_at": "\(iso.string(from: now.addingTimeInterval(-writtenAgo)))", \
        "stale_after_minutes": \(staleAfter[app, default: 60]), "summary": \(body)}
        """
    }

    /// Each app's own window (docs/hive-feed/*.json).
    static let staleAfter: [String: Int] = [
        "hivemind": 90, "hive-tempo": 90, "health-score": 120, "hiveworld": 1560, "ai-business-db": 360,
        "releases": 11520, "ideas": 11520, "iphone": 11520, "jobs": 90, "tools": 10080,
    ]

    static let normal: [String: String] = [
        "hivemind": """
        {"quota": [{"ai": "claude", "left_pct": 64, "read_at": "{{recent}}"}, {"ai": "codex", "left_pct": 22, "read_at": "{{recent}}"}],
         "alerts": [{"kind": "sample", "text": "Sample alert: the test Mac is on battery", "at": "{{recent}}"}],
         "now": "Sample improvement: answer in under 10 s"}
        """,
        "hive-tempo": """
        {"date": "{{today}}", "state": "inProgress", "done": 2, "total": 5,
         "current": {"title": "Sample task: water the plants", "until": "{{later}}"}, "next": {"title": "Sample task: read a chapter", "at": "{{later}}"}}
        """,
        "health-score": """
        {"method": 8, "score": 72, "word": "Good", "capped": false,
         "top_fixes": [{"id": "sample.tests", "repo": "example/sample-app", "title": "Add a test for the sample screen", "points": 12}],
         "repos": [{"repo": "sample-app", "score": 72}]}
        """,
        "hiveworld": """
        {"schema_version": 1, "pick": ["example/sample-app"],
         "projects": [{"id": "example/sample-app", "name": "sample-app", "need": 0.6, "reason": "Sample reason: score dropped", "paused": false},
                      {"id": "example/paused-app", "name": "paused-app", "need": null, "reason": null, "paused": true}]}
        """,
        "ai-business-db": """
        {"day": 12, "days_total": 90, "ends": "{{day+78}}", "earned_usd": 41.5,
         "routes": [{"name": "Sample Shop", "status": "10 sample listings", "earned_usd": 41.5}, {"name": "Sample Route", "status": "waiting", "earned_usd": null}],
         "next_checkpoint": {"date": "{{day+14}}", "title": "sample review"},
         "income": {"net_usd": 41.5, "month_net_usd": 20.0, "pending_usd": 5.0, "sales": 6, "by_route": {"Sample Shop": 41.5},
                    "month": "{{month}}", "month_by_route": {"Sample Shop": 20.0}, "goal_usd": 100,
                    "last_sale": {"date": "{{today}}", "route": "Sample Shop", "item": "Sample item", "net_usd": 4.0},
                    "payouts": {"next": {"date": "{{day+5}}", "usd": 5.0}, "waiting_usd": 5.0, "paid_usd": 36.5, "overdue": [], "overdue_usd": 0}},
         "budget": {"month_usd": 30.0, "items": [{"name": "Sample plan", "usd_month": 20.0, "estimate": false}, {"name": "Sample tool", "usd_month": 10.0, "estimate": true}],
                    "estimates": 1, "credit": [{"project": "sample-app", "allot_usd": 25, "used_usd": 4.2}],
                    "renewals": [{"item": "Sample plan", "project": "sample-app", "date": "{{day+20}}", "decide_by": "{{day+13}}", "cost": "$20/mo", "decision": "keep"}]},
         "lab": {"running": 1, "completed": 0, "due_for_check": 0, "pilot_unused_days": 0, "pilot_stop_after_days": 14,
                 "experiments": [{"id": "sample-title-test", "route": "Sample Shop", "status": "running", "started_on": "{{day-3}}", "check_on": "{{day+4}}", "metric": "sample_orders", "observed_direction": "insufficient_data", "causation": "none_measured", "decision": null}]}}
        """,
        "releases": """
        {"app": "SampleApp", "version": "1.0", "build": "20990101.1200", "commit": "0000000", "at": "{{recent}}",
         "ready": true, "override": null, "tests_passed": 42, "screens": 3, "under_load": false,
         "baseline": "20990101.0900", "changes": ["Sample change: new card", "Sample change: docs"], "checks": ["Sample change: new card"],
         "apps": [{"app": "SampleApp", "version": "1.0", "build": "20990101.1200", "commit": "0000000", "at": "{{recent}}",
                   "ready": true, "tests_passed": 42, "screens": 3, "under_load": false, "baseline": "20990101.0900",
                   "changes": ["Sample change: new card", "Sample change: docs"], "checks": ["Sample change: new card"]},
                  {"app": "SampleTwo", "version": "2.1", "build": "20990101.0800", "commit": "1111111", "at": "{{recent}}",
                   "ready": false, "override": "Sample override: simulator down", "tests_passed": 7, "screens": 0,
                   "under_load": true, "baseline": null, "changes": [], "checks": []}]}
        """,
        "ideas": """
        {"ideas": [{"asked_on": "{{today}}", "n": 1, "kind": "feature", "title": "Sample idea", "why_now": "Sample reason",
                    "reuses": "Hive feed", "size": "S", "ais": ["claude"]}]}
        """,
        "tools": """
        {"week": [{"id": "connector:Sample Search", "kind": "connector", "uses": 40},
                  {"id": "sample-skill", "kind": "skill", "uses": 12},
                  {"id": "sample-kit:sample-plan", "kind": "skill", "uses": 5}],
         "weeks": [{"week_to": "{{today}}", "uses_total": 57}, {"week_to": "{{day-7}}", "uses_total": 31},
                   {"week_to": "{{day-14}}", "uses_total": 0}, {"week_to": "{{day-21}}", "uses_total": 8},
                   {"week_to": "{{day-28}}", "uses_total": 2}],
         "top_plugins": [{"plugin": "sample-kit", "uses": 5}],
         "top_connectors": [{"name": "Sample Search", "uses": 40}],
         "installed": {"skills": 20, "plugins": 3, "connectors": 4}, "never_used": 24}
        """,
        "jobs": """
        {"counts": {"failed": 3, "running": 1, "waiting": 2, "finished": 4},
         "issues": [{"cause": "sign-in or permission refused", "jobs": ["sample-pins", "sample-routine"]},
                    {"cause": "stopped with exit code 1 and no message", "jobs": ["sample-backup"]}],
         "jobs": [{"kind": "launchd", "name": "sample-backup", "status": "failed", "detail": "exit 1.",
                   "last_ok": {"at": "{{today}} 04:00", "output": "Sample: 12 files copied"}},
                  {"kind": "task", "name": "sample-pins", "status": "failed", "at": "09:00", "cause": "sign-in or permission refused"},
                  {"kind": "routine", "name": "sample-routine", "status": "failed", "at": "09:30", "cause": "sign-in or permission refused"},
                  {"kind": "launchd", "name": "sample-server", "status": "running", "output": "Sample: listening"},
                  {"kind": "launchd", "name": "sample-weekly", "status": "waiting", "next": "{{day+3}} 06:10"},
                  {"kind": "launchd", "name": "sample-night", "status": "finished", "output": "Sample: 3 renders", "next": "{{today}} 23:15"},
                  {"kind": "launchd", "name": "sample-sync", "status": "finished", "every_minutes": 30},
                  {"kind": "task", "name": "sample-evening", "status": "waiting"},
                  {"kind": "launchd", "name": "sample-cleanup", "status": "finished", "output": "Sample: freed 1.2 GB"},
                  {"kind": "task", "name": "sample-morning", "status": "finished", "at": "07:00"}],
         "problems": []}
        """,
        "iphone": """
        {"scanned": "{{today}}T09:00", "free_gb": 18.5, "total_gb": 128.0, "free_pct": 14.5, "battery_health_pct": 88.0,
         "ios": "27.0", "ios_latest": "27.1", "update_pending": true}
        """,
    ]

    static let empty: [String: String] = [
        "hivemind": #"{"quota": [], "alerts": [], "now": null}"#,
        "hive-tempo": #"{"date": "{{today}}", "state": "empty", "done": 0, "total": 0, "current": null, "next": null}"#,
        "health-score": #"{"method": 8, "score": 0, "word": "No data", "capped": false, "top_fixes": [], "repos": []}"#,
        "hiveworld": #"{"schema_version": 1, "pick": [], "projects": []}"#,
        "ai-business-db": """
        {"day": 1, "days_total": 90, "ends": "{{day+89}}", "earned_usd": 0, "routes": [], "next_checkpoint": null,
         "income": {"net_usd": 0, "month_net_usd": 0, "pending_usd": 0, "sales": 0, "by_route": {}, "month": "{{month}}",
                    "month_by_route": {}, "goal_usd": 100, "last_sale": null,
                    "payouts": {"next": null, "waiting_usd": 0, "paid_usd": 0, "overdue": [], "overdue_usd": 0}},
         "budget": {"month_usd": 0, "items": [], "estimates": 0, "credit": [], "renewals": []},
         "lab": {"running": 0, "completed": 0, "due_for_check": 0, "pilot_unused_days": 0, "pilot_stop_after_days": 14, "experiments": []}}
        """,
        "releases": """
        {"app": "SampleApp", "version": "0.1", "build": "20990101.0000", "commit": "0000000", "at": "{{recent}}",
         "ready": false, "override": null, "tests_passed": null, "screens": null, "under_load": null}
        """,
        "ideas": #"{"ideas": []}"#,
        "jobs": #"{"counts": {"failed": 0, "running": 0, "waiting": 0, "finished": 0}, "issues": [], "jobs": [], "problems": []}"#,
        "tools": """
        {"week": [], "weeks": [{"week_to": "{{today}}", "uses_total": 0}], "top_plugins": [], "top_connectors": [],
         "installed": {"skills": 0, "plugins": 0, "connectors": 0}, "never_used": 0}
        """,
        "iphone": """
        {"scanned": "{{today}}T09:00", "free_gb": null, "total_gb": null, "free_pct": null, "battery_health_pct": null,
         "ios": null, "ios_latest": null, "update_pending": false}
        """,
    ]
}
