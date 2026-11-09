import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HiveKit

/// The ☰ menu's "Hive apps" rows (docs/superpowers/specs/2026-11-09-hive-switcher-design.md).
struct HiveStatusTests {
    let ny = TimeZone(identifier: "America/New_York")!
    let now = ISO8601DateFormatter().date(from: "2026-11-09T15:00:00Z")!

    @Test func appsKnowTheirFeedNameAndURL() {
        #expect(HiveApp.allCases.map(\.feedName) == ["hivemind", "health-score", "hive-tempo"])
        #expect(HiveApp.score.url.absoluteString == "hivescore://")
        #expect(HiveApp.mind.name == "HiveMind")
    }

    @Test func scoreLine() {
        let s = ScoreSummary(method: 9, score: 99, word: "Good", capped: false, topFixes: [])
        #expect(HiveStatus.line(s) == "99 · Good")
        #expect(HiveStatus.line(ScoreSummary(method: 9, score: 60, word: "Fair", capped: true, topFixes: []))
                == "60 · capped by a safety problem")
    }

    @Test func tempoLine() {
        let next = TempoSummary.Task(title: "Post today's TikTok", until: nil, at: "16:00")
        #expect(HiveStatus.line(TempoSummary(date: "2026-11-09", state: "scheduled", done: 2, total: 5, current: nil, next: next))
                == "2 of 5 done · next: Post today's TikTok 4:00 pm")
        #expect(HiveStatus.line(TempoSummary(date: "2026-11-09", state: "finished", done: 5, total: 5, current: nil, next: nil))
                == "All 5 done")
        #expect(HiveStatus.line(TempoSummary(date: "2026-11-09", state: "empty", done: 0, total: 0, current: nil, next: nil))
                == "Nothing planned today")
        let noon = TempoSummary.Task(title: "Lunch", until: nil, at: "12:05")
        #expect(HiveStatus.line(TempoSummary(date: "2026-11-09", state: "scheduled", done: 0, total: 1, current: nil, next: noon))
                == "0 of 1 done · next: Lunch 12:05 pm")
    }

    @Test func mindLine() {
        let q = [HiveMindSummary.Quota(ai: "claude", leftPct: nil, readAt: nil),
                 HiveMindSummary.Quota(ai: "codex", leftPct: 86, readAt: nil),
                 HiveMindSummary.Quota(ai: "gemini", leftPct: 40, readAt: nil)]
        let a = [HiveMindSummary.Alert(kind: "on_battery", text: "x", at: nil), .init(kind: "all_failed", text: "y", at: nil)]
        #expect(HiveStatus.line(HiveMindSummary(quota: q, alerts: a, now: nil)) == "Gemini 40% left · 2 alerts")
        #expect(HiveStatus.line(HiveMindSummary(quota: [], alerts: [a[0]], now: nil)) == "1 alert")
        #expect(HiveStatus.line(HiveMindSummary(quota: [], alerts: [], now: nil)) == "No alerts")
    }

    @Test func staleStatusSaysWhen() {
        let written = ISO8601DateFormatter().date(from: "2026-11-09T14:26:00Z")!
        let s = HiveStatus(app: .tempo, line: "2 of 5 done", written: written, stale: true)
        #expect(s.shown(timeZone: ny) == "not updated since 9:26 am")
        #expect(HiveStatus(app: .tempo, line: "2 of 5 done", written: written, stale: false).shown(timeZone: ny) == "2 of 5 done")
    }

    @Test func statusesSkipSelfAndSurviveAFailure() async throws {
        let feed = HiveFeedTests()
        let score = try feed.fixture("health-score")
        let stub = StubTransport { req in
            let u = req.url!.absoluteString
            if u.contains("health-score.json") { return feed.contents(score) }
            return json(["message": "boom"], status: 500)
        }
        let rows = await HiveFeedReader(client: feed.client(stub)).statuses(except: .tempo, now: now)
        #expect(rows.map(\.app) == [.mind, .score])
        #expect(rows[0].line == "No status yet")
        let want = try #require(try HiveFeed.decode(score, as: ScoreSummary.self)).summary.score
        #expect(rows[1].line.hasPrefix("\(want) · "))
        #expect(!stub.requests.contains { $0.url!.absoluteString.contains("hive-tempo.json") })
    }
}
