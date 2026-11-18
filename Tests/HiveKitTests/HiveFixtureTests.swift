import Foundation
import Testing
@testable import HiveKit

struct HiveFixtureTests {
    let now = ISO8601DateFormatter().date(from: "2099-01-15T12:00:00Z")!

    struct NoFile: Error {}

    func feed<S: Decodable & Sendable>(_ app: String, _ scenario: HiveFixture.Scenario, as type: S.Type) throws -> HiveFeedEnvelope<S>? {
        guard let data = try HiveFixture.file(app, scenario, now: now) else { throw NoFile() }
        return try HiveFeed.decode(data, as: type)
    }

    @Test func sameNowSameBytes() throws {
        for app in HiveFixture.apps {
            for scenario in HiveFixture.Scenario.allCases where scenario != .offline {
                #expect(try HiveFixture.file(app, scenario, now: now) == HiveFixture.file(app, scenario, now: now))
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
        let rows = await HiveFixture.preview(now: now)
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
        let empty = try feed("ai-business-db", .empty, as: BusinessSummary.self)
        #expect(empty.flatMap { IncomeGoal($0.summary) }?.bestRoute == nil)
        let stale = try feed("hive-tempo", .stale, as: TempoSummary.self)
        #expect(stale?.isStale(now: now) == true)
        #expect(try feed("hivemind", .empty, as: HiveMindSummary.self).map { HiveStatus.line($0.summary) } == "No alerts")
    }

    /// Fictional only: the repo is public and the fixtures are shown in screenshots.
    @Test func noPersonalData() throws {
        for app in HiveFixture.apps {
            for scenario in [HiveFixture.Scenario.normal, .empty] {
                guard let data = try HiveFixture.file(app, scenario, now: now) else { throw NoFile() }
                let text = String(decoding: data, as: UTF8.self)
                for word in ["ndabney", "Noah", "Dink", "Etsy", "TikTok", "@", "ghu_", "ghp_"] {
                    #expect(!text.contains(word), "\(app) \(scenario.rawValue) contains \(word)")
                }
            }
        }
    }

    @Test func offlineThrowsOffline() async {
        await #expect(throws: FetchError.offline) {
            _ = try await HiveFixture.reader(.offline, now: { now }).read("hivemind", as: HiveMindSummary.self)
        }
    }
}
