import Foundation

/// A writing voice any AI can follow (Hive build order #36, Voice 18): approved examples, corrections the writer made
/// (before → after, and why), do and never rules, turned into one paste-ready style brief per AI. The profile is the
/// writer's own JSON file; hive-kit only holds the format, so each app's and each person's voice stays in their own
/// file (HiveRounds keeps its providers' style on their phones). Tool: `hive-voice brief | check | correct`.
public struct VoiceProfile: Codable, Equatable, Sendable {
    public struct Example: Codable, Equatable, Sendable {
        public var text: String
        /// What makes it good ("leads with the answer").
        public var note: String?
        /// "2026-11-18"
        public var approved: String

        public init(text: String, note: String? = nil, approved: String) {
            self.text = text; self.note = note; self.approved = approved
        }
    }

    public struct Correction: Codable, Equatable, Sendable {
        public var before: String
        public var after: String
        public var why: String?
        /// "2026-11-18"
        public var date: String

        public init(before: String, after: String, why: String? = nil, date: String) {
            self.before = before; self.after = after; self.why = why; self.date = date
        }
    }

    public var schema = 1
    /// "Hive docs"
    public var name: String
    /// What it is used for ("HANDOFF.md files and docs in AI.Stuff").
    public var usedFor: String
    public var audience: String?
    /// "plain", "direct", "calm"
    public var tone: [String]
    public var rules: [String]
    /// Words and phrases never to use (`check` finds them, case-insensitive, whole words).
    public var never: [String]
    public var examples: [Example]
    public var corrections: [Correction]

    public init(name: String, usedFor: String, audience: String? = nil, tone: [String] = [], rules: [String] = [],
                never: [String] = [], examples: [Example] = [], corrections: [Correction] = []) {
        self.name = name; self.usedFor = usedFor; self.audience = audience; self.tone = tone; self.rules = rules
        self.never = never; self.examples = examples; self.corrections = corrections
    }

    public static func decode(_ data: Data) throws -> VoiceProfile { try JSONDecoder().decode(Self.self, from: data) }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// Keeps a correction; the same before → after again only moves to the newest date (no duplicates).
    public mutating func correct(_ c: Correction) {
        corrections.removeAll { $0.before == c.before && $0.after == c.after }
        corrections.append(c)
    }

    /// The `never` words in `text`, in profile order: "never: hub (line 3)".
    public func check(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for word in never where !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for (i, line) in lines.enumerated()
            where re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                out.append("never: \(word) (line \(i + 1))")
            }
        }
        return out
    }
}

/// Who reads the brief. The rules are the same; the opening and closing lines fit how each app takes a style.
public enum VoiceTarget: String, CaseIterable, Sendable {
    case claude, chatgpt, gemini, generic
}

extension VoiceProfile {
    /// A paste-ready style brief, at most `maxChars` long: rules and never-words always stay; the oldest examples and
    /// corrections go first when it is too long (newest corrections are kept: they are the latest word).
    public func brief(for target: VoiceTarget = .generic, maxChars: Int = 6000) -> String {
        var ex = Array(examples.suffix(3))
        var co = Array(corrections.suffix(8))
        var text = render(target, ex, co)
        while text.count > maxChars, !(ex.isEmpty && co.isEmpty) {
            if ex.count >= co.count, !ex.isEmpty { ex.removeFirst() } else { co.removeFirst() }
            text = render(target, ex, co)
        }
        return text
    }

    private func render(_ target: VoiceTarget, _ ex: [Example], _ co: [Correction]) -> String {
        var s: [String] = []
        switch target {
        case .claude: s.append("Write in the style below for everything in this conversation.")
        case .chatgpt: s.append("For the rest of this chat, write in the style below. Don't mention the style.")
        case .gemini: s.append("Follow this writing style in every reply in this chat.")
        case .generic: s.append("Writing style to follow.")
        }
        s.append("")
        s.append("# Writing style: \(name)")
        s.append("Use it for: \(usedFor)")
        if let audience { s.append("Readers: \(audience)") }
        if !tone.isEmpty { s.append("Tone: \(tone.joined(separator: ", "))") }
        if !rules.isEmpty {
            s.append("")
            s.append("## Do")
            s += rules.map { "- \($0)" }
        }
        if !never.isEmpty {
            s.append("")
            s.append("## Never use")
            s.append(never.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        if !co.isEmpty {
            s.append("")
            s.append("## Corrections the writer made (newest last)")
            s += co.map { "- \"\($0.before)\" → \"\($0.after)\"" + ($0.why.map { " (\($0))" } ?? "") }
        }
        if !ex.isEmpty {
            s.append("")
            s.append("## Approved examples")
            for e in ex {
                s.append("")
                s += e.text.components(separatedBy: "\n").map { "> \($0)" }
                if let note = e.note { s.append("Why it works: \(note)") }
            }
        }
        return s.joined(separator: "\n") + "\n"
    }
}
