import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HiveKit

struct HiveFeedTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../docs/hive-feed").standardized

    func fixture(_ app: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent("\(app).json")) }

    func client(_ stub: StubTransport) -> GitHubClient {
        let clock = TestClock()
        let flow = DeviceFlow(clientID: "Iv1.test", transport: StubTransport(script: []), now: clock.now, sleep: clock.sleep)
        let safe = MemorySafe(Token(accessToken: "ghu_a", expiresAt: clock.now().addingTimeInterval(3600),
                                    refreshToken: "ghr_a", refreshExpiresAt: clock.now().addingTimeInterval(86400)))
        return GitHubClient(keeper: TokenKeeper(flow: flow, safe: safe), transport: stub, now: clock.now)
    }

    /// The contents API wraps the file in base64.
    func contents(_ data: Data, status: Int = 200) -> HTTPReply {
        json(["encoding": "base64", "content": data.base64EncodedString(options: .lineLength76Characters)], status: status)
    }

    @Test func decodesEachFixture() throws {
        let mind = try HiveFeed.decode(fixture("hivemind"), as: HiveMindSummary.self)
        #expect(mind?.summary.quota.first?.leftPct == 90)
        #expect(mind?.summary.alerts.first?.kind == "on_battery")
        let tempo = try HiveFeed.decode(fixture("hive-tempo"), as: TempoSummary.self)
        #expect(tempo?.summary.state == "inProgress")
        #expect(tempo?.summary.current?.until == "14:30")
        #expect(tempo?.detail?.branch == "tempo")
        let score = try HiveFeed.decode(fixture("health-score"), as: ScoreSummary.self)
        #expect(score?.summary.topFixes[0].points == 40)
        #expect(score?.summary.capped == true)
        #expect(score?.app == "health-score")
        let business = try HiveFeed.decode(fixture("ai-business-db"), as: BusinessSummary.self)
        #expect(business?.summary.daysTotal == 90)
        #expect(business?.summary.routes.first?.earnedUsd == 12.5)
        #expect(business?.summary.routes.last?.earnedUsd == nil)
        #expect(business?.summary.nextCheckpoint?.title == "route review")
    }

    @Test func unknownFieldsIgnored() throws {
        var doc = try JSONSerialization.jsonObject(with: fixture("health-score")) as! [String: Any]
        doc["future"] = ["x": 1]
        let feed = try HiveFeed.decode(JSONSerialization.data(withJSONObject: doc), as: ScoreSummary.self)
        #expect(feed?.summary.score == 60)
    }

    @Test func staleAfterWindow() throws {
        let feed = try #require(try HiveFeed.decode(fixture("hive-tempo"), as: TempoSummary.self))
        let written = ISO8601DateFormatter().date(from: "2026-11-08T19:00:00Z")!
        #expect(!feed.isStale(now: written.addingTimeInterval(89 * 60)))
        #expect(feed.isStale(now: written.addingTimeInterval(91 * 60)))
    }

    @Test func schema2IsSkipped() throws {
        var doc = try JSONSerialization.jsonObject(with: fixture("hivemind")) as! [String: Any]
        doc["schema"] = 2
        #expect(try HiveFeed.decode(JSONSerialization.data(withJSONObject: doc), as: HiveMindSummary.self) == nil)
    }

    @Test func missingFileIsNil() async throws {
        let stub = StubTransport { _ in json(["message": "Not Found"], status: 404) }
        #expect(try await HiveFeedReader(client: client(stub)).read("hive-tempo", as: TempoSummary.self) == nil)
    }

    @Test func readsContentsAPIWithRef() async throws {
        let data = try fixture("hive-tempo")
        let stub = StubTransport { [self] _ in contents(data) }
        let feed = try await HiveFeedReader(client: client(stub)).read("hive-tempo", as: TempoSummary.self)
        #expect(feed?.summary.done == 3)
        #expect(stub.requests[0].url?.absoluteString
                == "https://api.github.com/repos/ndabney562/hivemind/contents/hive-tempo.json?ref=hive")
        #expect(stub.requests[0].httpMethod == "GET")
    }
}
