import Foundation
import Testing
@testable import HiveKit

struct HiveFixtureTests {
    let now = ISO8601DateFormatter().date(from: "2099-01-15T12:00:00Z")!
    let utc = TimeZone(identifier: "UTC")!

    struct NoFile: Error {}

    func feed<S: Decodable & Sendable>(_ app: String, _ scenario: HiveFixture.Scenario, as type: S.Type) throws -> HiveFeedEnvelope<S>? {
        guard let data = try HiveFixture.file(app, scenario, now: now, timeZone: utc) else { throw NoFile() }
        return try HiveFeed.decode(data, as: type)
    }

    @Test func sameNowSameBytes() throws {
        for app in HiveFixture.apps {
            for scenario in HiveFixture.Scenario.allCases where scenario != .offline {
                #expect(try HiveFixture.file(app, scenario, now: now, timeZone: utc) == HiveFixture.file(app, scenario, now: now, timeZone: utc))
            }
        }
    }

    @Test func launchArgument() {
        #expect(HiveFixture.scenario(arguments: ["App", "-hive-fixture", "stale"]) == .stale)
        #expect(HiveFixture.scenario(arguments: ["App"]) == nil)
        #expect(HiveFixture.scenario(arguments: ["App", "-hive-fixture"]) == nil)
        #expect(HiveFixture.scenario(arguments: ["App", "-hive-fixture", "sideways"]) == nil)
    }

    @Test func everyAppInEveryScenario() async {
        let rows = await HiveFixture.preview(now: now, timeZone: utc)
        #expect(rows.count == HiveFixture.apps.count * HiveFixture.Scenario.allCases.count)
        let want: [HiveFixture.Scenario: HiveFixture.Outcome] = [
            .normal: .shown, .empty: .shown, .missing: .noFile, .stale: .shownAsOld, .offline: .offline, .malformed: .unreadable,
        ]
        for row in rows {
            #expect(row.outcome == want[row.scenario], "\(row.app) \(row.scenario.rawValue): \(row.outcome.rawValue)")
        }
    }

    /// The fixtures cover every feed the docs describe with a summary in hive-kit, in the same shape.
    @Test func sameShapeAsTheDocsExamples() throws {
        #expect(Set(HiveFixture.apps).isSuperset(of: ["hivemind", "hive-tempo", "health-score", "hiveworld", "ai-business-db", "iphone"]))
        let mind = try feed("hivemind", .normal, as: HiveMindSummary.self)
        #expect(mind?.summary.quota.count == 2)
        let tempo = try feed("hive-tempo", .normal, as: TempoSummary.self)
        #expect(tempo?.summary.date == "2099-01-15")
        #expect(tempo?.summary.current?.until == "13:00")
        #expect(tempo?.isStale(now: now) == false)
        let business = try feed("ai-business-db", .normal, as: BusinessSummary.self)
        #expect(business.flatMap { IncomeGoal($0.summary) }?.bestRoute == "Sample Shop")
        #expect(business?.summary.budget?.renewals?.count == 1)
        // Relative to now, so "this month" and "soon" stay true (HiveScore marked a 2099 month as old)
        #expect(business?.summary.income?.month == "2099-01")
        #expect(business?.summary.income?.payouts?.next?.date == "2099-01-20")
        #expect(business?.summary.budget?.renewals?.first?.date == "2099-02-04")
        let empty = try feed("ai-business-db", .empty, as: BusinessSummary.self)
        #expect(empty.flatMap { IncomeGoal($0.summary) }?.bestRoute == nil)
        let stale = try feed("hive-tempo", .stale, as: TempoSummary.self)
        #expect(stale?.isStale(now: now) == true)
        #expect(try feed("hivemind", .empty, as: HiveMindSummary.self).map { HiveStatus.line($0.summary) } == "No alerts")
        let jobs = try feed("jobs", .normal, as: JobsSummary.self)
        #expect(jobs?.summary.issues.first?.jobs == ["sample-pins", "sample-routine"])
        #expect(jobs?.summary.jobs.first?.lastOk?.output == "Sample: 12 files copied")
        #expect(jobs?.summary.counts.failed == 3)
    }

    /// Fictional only: the repo is public and the fixtures are shown in screenshots.
    @Test func noPersonalData() throws {
        for app in HiveFixture.apps {
            for scenario in [HiveFixture.Scenario.normal, .empty] {
                guard let data = try HiveFixture.file(app, scenario, now: now, timeZone: utc) else { throw NoFile() }
                let text = String(decoding: data, as: UTF8.self)
                for word in ["ndabney", "Noah", "Dink", "Etsy", "TikTok", "@", "ghu_", "ghp_"] {
                    #expect(!text.contains(word), "\(app) \(scenario.rawValue) contains \(word)")
                }
            }
        }
    }

    /// HiveScore compares hive-tempo's `date` with its own local day: late evening in New York is already
    /// tomorrow in UTC, so the fixture's day must be the reader's (the sample plan vanished at 21:00 New York time).
    @Test func todayIsTheReadersDay() throws {
        let evening = ISO8601DateFormatter().date(from: "2099-01-16T02:30:00Z")!  // 21:30 on the 15th in New York
        let ny = TimeZone(identifier: "America/New_York")!
        let data = try #require(try HiveFixture.file("hive-tempo", .normal, now: evening, timeZone: ny))
        let tempo = try HiveFeed.decode(data, as: TempoSummary.self)
        #expect(tempo?.summary.date == "2099-01-15")
        #expect(tempo?.summary.current?.until == "22:30")
    }

    @Test func offlineThrowsOffline() async {
        await #expect(throws: FetchError.offline) {
            _ = try await HiveFixture.reader(.offline, now: { now }, timeZone: utc).read("hivemind", as: HiveMindSummary.self)
        }
    }
}
