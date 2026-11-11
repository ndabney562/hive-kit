import Foundation
import Testing
@testable import HiveKit

/// The "How to use" guide's data and rules (hive-design plan docs/superpowers/plans/2026-11-11-hive-guide.md, Task 1).
@Suite struct GuideTests {
    func card(_ id: String, title: String? = nil, screen: String = "home", changed: String = "20261111.0814",
              welcome: Bool = false, steps: Int = 3) -> GuideCard {
        GuideCard(id: id, title: title ?? "How do I \(id)?", steps: (0..<steps).map { "Step \($0 + 1)" }, screen: screen, changed: changed, welcome: welcome)
    }

    @Test func loadsValidFile() throws {
        let json = #"{"cards":[{"id":"a","title":"How do I add a repo?","steps":["1","2","3"],"screen":"repos","changed":"20261111.0814"}]}"#
        let guide = try #require(Guide.load(Data(json.utf8)))
        #expect(guide.cards.count == 1)
        #expect(guide.cards[0].welcome == false)
        #expect(guide.cards[0].screen == "repos")
    }

    @Test func missingOrBrokenFileIsNil() {
        #expect(Guide.load(nil) == nil)
        #expect(Guide.load(Data("{".utf8)) == nil)
        #expect(Guide.load(Data(#"{"cards":[]}"#.utf8)) == nil)
    }

    @Test func bundledMissingFileIsNil() throws {
        let bundle = try #require(Bundle(path: NSTemporaryDirectory()))
        #expect(Guide.bundled(bundle) == nil)
    }

    @Test func searchMatchesTitleAndSteps() {
        var c = card("export")
        c.steps = ["Open the menu", "Tap Repos", "Tap Export"]
        let guide = Guide(cards: [c, card("other")])
        #expect(guide.search("repo").map(\.id) == ["export"])
        #expect(guide.search("banana").isEmpty)
        #expect(guide.search("").count == 2)
    }

    @Test func searchIgnoresCaseAccentsAndSpaces() {
        let guide = Guide(cards: [card("x", title: "How do I export?")])
        #expect(guide.search("  How DO i  expórt ").map(\.id) == ["x"])
    }

    @Test func firstLaunchShowsNothing() {
        let guide = Guide(cards: [card("a"), card("b", welcome: true)])
        #expect(GuideLaunch.cards(guide: guide, build: "20261111.0814", lastSeen: nil, welcome: false).isEmpty)
    }

    @Test func welcomeOptInMaxThree() {
        let guide = Guide(cards: (1...5).map { card("w\($0)", welcome: true) })
        #expect(GuideLaunch.cards(guide: guide, build: "20261111.0814", lastSeen: nil, welcome: true).map(\.id)
                == ["w1", "w2", "w3"])
        #expect(GuideLaunch.cards(guide: guide, build: "20261111.0814", lastSeen: nil, welcome: false).isEmpty)
        // After the first launch, welcome cards show only if they changed.
        #expect(GuideLaunch.cards(guide: guide, build: "20261111.0814", lastSeen: "20261111.0814", welcome: true).isEmpty)
    }

    @Test func newerBuildShowsOnlyChangedCards() {
        let guide = Guide(cards: [card("old", changed: "20261101.0900"), card("new", changed: "20261111.0814"),
                                  card("future", changed: "20261120.1000")])
        #expect(GuideLaunch.cards(guide: guide, build: "20261111.0814", lastSeen: "20261105.0000", welcome: false)
                    .map(\.id) == ["new"])
    }

    @Test func sameOrOlderBuildShowsNothing() {
        let guide = Guide(cards: [card("a", changed: "20261111.0814")])
        #expect(GuideLaunch.cards(guide: guide, build: "20261111.0814", lastSeen: "20261111.0814", welcome: false).isEmpty)
        #expect(GuideLaunch.cards(guide: guide, build: "20261105.0000", lastSeen: "20261111.0814", welcome: false).isEmpty)
    }

    @Test func unparseableBuildShowsNothing() throws {
        let guide = Guide(cards: [card("a", welcome: true)])
        #expect(GuideLaunch.cards(guide: guide, build: "1", lastSeen: "20261101.0000", welcome: true).isEmpty)
        #expect(GuideLaunch.cards(guide: guide, build: "", lastSeen: nil, welcome: true).isEmpty)
        let defaults = try #require(UserDefaults(suiteName: "guide-test-\(UUID())"))
        _ = GuideLaunch.take(guide: guide, build: "1", defaults: defaults, welcome: true)
        #expect(defaults.string(forKey: GuideLaunch.key) == nil)
    }

    @Test func takeShowsOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "guide-test-\(UUID())"))
        let guide = Guide(cards: [card("a", changed: "20261101.0900"), card("b", changed: "20261111.0814")])
        let first = GuideLaunch.take(guide: guide, build: "20261105.0000", defaults: defaults, welcome: false)
        #expect(first.cards.isEmpty && !first.isWelcome)
        #expect(defaults.string(forKey: GuideLaunch.key) == "20261105.0000")
        let second = GuideLaunch.take(guide: guide, build: "20261111.0814", defaults: defaults, welcome: false)
        #expect(second.cards.map(\.id) == ["b"])
        #expect(GuideLaunch.take(guide: guide, build: "20261111.0814", defaults: defaults, welcome: false).cards.isEmpty)
        // No guide: nothing shown, the build is still stored.
        #expect(GuideLaunch.take(guide: nil, build: "20261112.0900", defaults: defaults, welcome: false).cards.isEmpty)
        #expect(defaults.string(forKey: GuideLaunch.key) == "20261112.0900")
    }

    @Test func welcomeIsFlagged() throws {
        let defaults = try #require(UserDefaults(suiteName: "guide-test-\(UUID())"))
        let r = GuideLaunch.take(guide: Guide(cards: [card("w", welcome: true)]), build: "20261111.0814",
                                 defaults: defaults, welcome: true)
        #expect(r.isWelcome && r.cards.map(\.id) == ["w"])
    }

    @Test func coverageFindsEachProblem() {
        let guide = Guide(cards: [card("short", steps: 2), card("ghosty", title: "Add a repo", screen: "ghost"),
                                  card("x"), card("x")])
        let p = GuideCoverage.problems(guide, screens: ["home", "repos"])
        #expect(p.contains("screen repos has no card"))
        #expect(p.contains("card ghosty: unknown screen ghost"))
        #expect(p.contains("card short: 2 steps, needs 3-5"))
        #expect(p.contains(#"card ghosty: title must start "How do I""#))
        #expect(p.contains("duplicate card id x"))
        #expect(p.count == 5)
    }

    @Test func coverageFlagsBadChangedAndTooManySteps() {
        let guide = Guide(cards: [card("a", changed: "soon", steps: 6)])
        let p = GuideCoverage.problems(guide, screens: ["home"])
        #expect(p == ["card a: 6 steps, needs 3-5", #"card a: changed "soon" is not a build number"#])
    }

    @Test func coverageCleanGuideHasNoProblems() {
        let guide = Guide(cards: [card("a"), card("b", screen: "repos", steps: 5)])
        #expect(GuideCoverage.problems(guide, screens: ["home", "repos"]).isEmpty)
    }

    @Test func buildNumberParse() {
        #expect(BuildNumber.parse("20261111.0814")! == (20261111, 814))
        #expect(BuildNumber.parse("1") == nil)
        #expect(BuildNumber.parse("2026111.0814") == nil)
        #expect(BuildNumber.parse("20261111.814") == nil)
    }
}
