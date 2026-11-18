import Foundation
import Testing
@testable import HiveKit

struct FeedContractTests {
    static let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../docs/hive-feed").standardized
    let now = ISO8601DateFormatter().date(from: "2099-01-15T12:00:00Z")!

    func problems(_ app: String, _ json: String) -> [String] {
        let contract = FeedContract.known.first { $0.app == app }!
        return contract.check(Data(json.utf8))
    }

    /// The docs examples are what publishers copy: each must pass the readers' types.
    @Test func everyDocsExamplePasses() throws {
        for contract in FeedContract.known {
            let url = Self.docs.appendingPathComponent("\(contract.app).json")
            guard let data = try? Data(contentsOf: url) else { continue }  // releases has no example
            #expect(contract.check(data) == [], "\(contract.app)")
        }
    }

    @Test func aMissingFieldIsNamedInTheFeedsOwnWords() {
        let p = problems("hive-tempo", """
        {"schema":1,"app":"hive-tempo","written_at":"2099-01-15T12:00:00Z","stale_after_minutes":90,
         "summary":{"date":"2099-01-15","state":"empty","total":0}}
        """)
        #expect(p == ["summary.done: missing"])
        let fixes = problems("health-score", """
        {"schema":1,"app":"health-score","written_at":"2099-01-15T12:00:00Z","stale_after_minutes":120,
         "summary":{"method":8,"score":60,"word":"Fair","capped":false,"top_fixes":[{"id":"a","repo":"r","title":"t"}]}}
        """)
        #expect(fixes == ["summary.top_fixes[0].points: missing"])
    }

    @Test func aChangedTypeIsCaught() {
        let p = problems("hive-tempo", """
        {"schema":1,"app":"hive-tempo","written_at":"2099-01-15T12:00:00Z","stale_after_minutes":90,
         "summary":{"date":"2099-01-15","state":"empty","done":"3","total":0}}
        """)
        #expect(p == ["summary.done: not a number"])
    }

    @Test func envelopeRules() {
        #expect(problems("ideas", "[1]") == ["not a JSON object"])
        #expect(problems("ideas", #"{"schema":2,"app":"ideas"}"#) == ["schema is 2, readers know 1"])
        let wrongApp = problems("ideas", """
        {"schema":1,"app":"idea","written_at":"2099-01-15T12:00:00Z","stale_after_minutes":60,"summary":{"ideas":[]}}
        """)
        #expect(wrongApp == [#"app is "idea", the file is ideas.json"#])
        #expect(problems("ideas", """
        {"schema":1,"app":"ideas","written_at":"yesterday","stale_after_minutes":60,"summary":{"ideas":[]}}
        """).first?.hasPrefix("written_at:") == true)
    }

    /// The fixtures: fresh and empty files pass, cut-off ones fail for every app, missing ones are not a problem.
    @Test func overTheFixtures() async {
        let utc = TimeZone(identifier: "UTC")!
        for scenario in [HiveFixture.Scenario.normal, .empty, .stale, .missing, .offline] {
            let found = await HiveFixture.reader(scenario, now: { now }, timeZone: utc).contractProblems()
            #expect(found == [], "\(scenario.rawValue): \(found)")
        }
        let broken = await HiveFixture.reader(.malformed, now: { now }, timeZone: utc).contractProblems()
        #expect(broken.map(\.app).sorted() == FeedContract.known.map(\.app).sorted())
        #expect(broken.allSatisfy { $0.problems == ["not a JSON object"] })
    }

    @Test func anAppAddsItsOwnReader() async {
        struct Phone: Decodable, Sendable { var freeGb: Double }
        let file = Data(#"{"schema":1,"app":"iphone","written_at":"2099-01-15T12:00:00Z","stale_after_minutes":60,"summary":{}}"#.utf8)
        let found = await HiveFeedReader { $0 == "iphone" ? file : nil }
            .contractProblems(extra: [FeedContract.Contract(app: "iphone", Phone.self)])
        #expect(found == [FeedContract.Result(app: "iphone", reader: "Phone", problems: ["summary.free_gb: missing"])])
    }
}
