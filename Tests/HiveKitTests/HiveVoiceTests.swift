import Foundation
import Testing
@testable import HiveKit

/// Hive build order #36 (Voice 18). A made-up profile: hive-kit is public and holds no real person's voice.
struct HiveVoiceTests {
    func profile() -> VoiceProfile {
        VoiceProfile(name: "Bakery notes", usedFor: "Shop updates for regulars", audience: "Neighbours who buy bread",
                     tone: ["warm", "short"], rules: ["Lead with what changed.", "Dates as 2026-11-18."],
                     never: ["synergy", "circle back"],
                     examples: [.init(text: "Rye is back on Fridays.\nCome early.", note: "One fact, then one action.",
                                      approved: "2026-11-01")],
                     corrections: [.init(before: "We are excited to announce", after: "New:", why: "no hype",
                                         date: "2026-11-02")])
    }

    @Test func briefHasEverySectionAndTheTargetsOpening() {
        let b = profile().brief(for: .chatgpt)
        #expect(b.hasPrefix("For the rest of this chat, write in the style below."))
        for part in ["# Writing style: Bakery notes", "Use it for: Shop updates for regulars", "Readers: Neighbours",
                     "Tone: warm, short", "## Do\n- Lead with what changed.", "## Never use\n\"synergy\", \"circle back\"",
                     "- \"We are excited to announce\" → \"New:\" (no hype)", "> Rye is back on Fridays.\n> Come early.",
                     "Why it works: One fact, then one action."] {
            #expect(b.contains(part), "missing: \(part)")
        }
        #expect(profile().brief(for: .claude).hasPrefix("Write in the style below"))
        #expect(profile().brief(for: .gemini).hasPrefix("Follow this writing style"))
    }

    @Test func aLongBriefDropsOldExamplesAndCorrectionsButNeverTheRules() {
        var p = profile()
        for i in 1...8 {
            p.examples.append(.init(text: String(repeating: "Example \(i). ", count: 40), approved: "2026-11-0\(i % 9 + 1)"))
            p.correct(.init(before: "old \(i)", after: "new \(i)", date: "2026-11-10"))
        }
        let b = p.brief(maxChars: 1200)
        #expect(b.count <= 1200)
        #expect(b.contains("- Lead with what changed."))
        #expect(b.contains("\"circle back\""))
        #expect(b.contains("\"old 8\" → \"new 8\""), "the newest correction stays")
        #expect(!b.contains("Example 1."), "the oldest example goes first")
    }

    @Test func checkFindsNeverWordsAsWholeWordsWithTheirLine() {
        let hits = profile().check("Fresh rolls.\nLet's Circle Back tomorrow.\nsynergyless is fine")
        #expect(hits == ["never: circle back (line 2)"])
    }

    @Test func aRepeatedCorrectionIsKeptOnceWithTheNewestDate() {
        var p = profile()
        p.correct(.init(before: "We are excited to announce", after: "New:", date: "2026-11-18"))
        #expect(p.corrections.count == 1)
        #expect(p.corrections[0].date == "2026-11-18")
    }

    @Test func profileRoundTripsThroughJSON() throws {
        let p = profile()
        #expect(try VoiceProfile.decode(p.encoded()) == p)
    }
}
