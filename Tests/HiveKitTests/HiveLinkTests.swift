import Foundation
import Testing
@testable import HiveKit

/// Hive build order #32 (Link 62): one route table that every Hive app builds and reads links with.
struct HiveLinkTests {
    @Test func everyRouteReadsBackAsItself() {
        for link in HiveLink.examples { #expect(HiveLink.parse(link.url) == link, "\(link.url)") }
    }

    @Test func urlsAreTheOnesTheAppsRegister() {
        #expect(HiveLink.tempoTask("reply-comments-2026-11-18").url.absoluteString == "hivetempo://task/reply-comments-2026-11-18")
        #expect(HiveLink.tempoToday.url.absoluteString == "hivetempo://today")
        #expect(HiveLink.open(.score).url == HiveApp.score.url)
        #expect(HiveLink.parse(URL(string: "HiveTempo://task/a-2026-11-18")!) == .tempoTask("a-2026-11-18"))
    }

    @Test func anythingElseIsNotAHiveLink() {
        for s in ["https://example.com/task/a", "hivetempo://task", "hivetempo://task/a/b", "hivetempo://task/A_B",
                  "hivetempo://task/a?x=1", "hivetempo://week", "hivescore://task/a", "mailto:a@b.c",
                  "hivetempo://task/" + String(repeating: "a", count: 121)] {
            #expect(HiveLink.parse(URL(string: s)!) == nil, "\(s)")
        }
    }

    @Test func aBadIDOpensTodayInsteadOfCrashing() {
        #expect(HiveLink.tempoTask("reply comments\n").url.absoluteString == "hivetempo://today")
        #expect(HiveLink.tempo(task: "a/b") == .tempoToday)
        #expect(HiveLink.tempo(task: nil) == .tempoToday)
        #expect(HiveLink.tempo(task: "a-2026-11-18") == .tempoTask("a-2026-11-18"))
    }

    @Test func fallbacksSayWhatHappened() {
        #expect(HiveLink.tempoTask("x").notInstalled.hasPrefix("HiveTempo isn't on this iPhone"))
        #expect(HiveLink.tempoTask("x").missing.contains("here is Today"))
        #expect(HiveLink.tempoToday.missing.isEmpty)
    }

    @Test func tempoFeedCarriesTaskIDs() throws {
        let data = try Data(contentsOf: HiveFeedTests.fixtures.appendingPathComponent("hive-tempo.json"))
        let feed = try #require(try HiveFeed.decode(data, as: TempoSummary.self))
        #expect(feed.summary.current?.id == "post-tiktok-2026-11-07")
        #expect(HiveLink.tempoTask(feed.summary.current!.id!).url.absoluteString == "hivetempo://task/post-tiktok-2026-11-07")
    }
}
