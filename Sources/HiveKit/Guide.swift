import Foundation

/// One "How do I…?" card of a Hive app's "How to use" guide (hive-design spec 2026-11-11-hive-guide-design.md).
/// The app ships them in `Guide.json` (`{"cards": [...]}`); hive-design draws them.
public struct GuideCard: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Starts "How do I".
    public var title: String
    /// 3-5 steps, in order.
    public var steps: [String]
    /// The screen id this card is about (each app lists its screens in its Kit's `GuideScreen`).
    public var screen: String
    /// The build that last changed this card, `YYYYMMDD.HHMM`; "What's new" shows cards changed since the last build seen.
    public var changed: String
    /// One of the (at most 3) first-launch welcome cards, in apps that opt in.
    public var welcome: Bool

    public init(id: String, title: String, steps: [String], screen: String, changed: String, welcome: Bool = false) {
        self.id = id
        self.title = title
        self.steps = steps
        self.screen = screen
        self.changed = changed
        self.welcome = welcome
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        steps = try c.decode([String].self, forKey: .steps)
        screen = try c.decode(String.self, forKey: .screen)
        changed = try c.decode(String.self, forKey: .changed)
        welcome = try c.decodeIfPresent(Bool.self, forKey: .welcome) ?? false
    }
}

/// An app's guide. A missing, broken or empty `Guide.json` gives nil: the app then shows no "How to use" row.
public struct Guide: Hashable, Sendable {
    public var cards: [GuideCard]

    public init(cards: [GuideCard]) { self.cards = cards }

    private struct File: Decodable { let cards: [GuideCard] }

    public static func load(_ data: Data?) -> Guide? {
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data), !file.cards.isEmpty else { return nil }
        return Guide(cards: file.cards)
    }

    public static func bundled(_ bundle: Bundle = .main) -> Guide? {
        load(bundle.url(forResource: "Guide", withExtension: "json").flatMap { try? Data(contentsOf: $0) })
    }

    /// The running app's guide, read once.
    public static let main: Guide? = bundled(.main)

    /// Cards whose title or steps hold every word of `query`, ignoring case and accents; an empty query gives all.
    public func search(_ query: String) -> [GuideCard] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return cards }
        return cards.filter { card in
            let text = Self.fold(([card.title] + card.steps).joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The apps' build numbers, `YYYYMMDD.HHMM` (e.g. `20261111.0814`). Anything else is not a build number.
public enum BuildNumber {
    public static func parse(_ s: String) -> (day: Int, time: Int)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts[1].count == 4,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let day = Int(parts[0]), let time = Int(parts[1]) else { return nil }
        return (day, time)
    }
}

/// What the guide shows by itself on launch: "What's new" after an update, or the welcome on a first launch.
public enum GuideLaunch {
    public static let key = "hive.guide.lastBuild"

    /// - First launch (`lastSeen` nil or not a build number): the first 3 welcome cards if `welcome`, else nothing.
    /// - Later: cards changed after `lastSeen` and no later than `build`, in file order.
    /// - `build` not a build number: nothing.
    public static func cards(guide: Guide, build: String, lastSeen: String?, welcome: Bool) -> [GuideCard] {
        guard let now = BuildNumber.parse(build) else { return [] }
        guard let seen = lastSeen.flatMap(BuildNumber.parse) else {
            return welcome ? Array(guide.cards.filter(\.welcome).prefix(3)) : []
        }
        return guide.cards.filter { card in
            guard let c = BuildNumber.parse(card.changed) else { return false }
            return seen < c && c <= now
        }
    }

    /// `cards`, then remembers `build` as seen (only when it is a build number), so each card shows once.
    public static func take(guide: Guide?, build: String, defaults: UserDefaults,
                            welcome: Bool) -> (cards: [GuideCard], isWelcome: Bool) {
        let lastSeen = defaults.string(forKey: key)
        let firstLaunch = lastSeen.flatMap(BuildNumber.parse) == nil
        let shown = guide.map { cards(guide: $0, build: build, lastSeen: lastSeen, welcome: welcome) } ?? []
        if BuildNumber.parse(build) != nil { defaults.set(build, forKey: key) }
        return (shown, firstLaunch && !shown.isEmpty)
    }
}

/// The check each app's Kit tests run on its `Guide.json`. An empty result means the guide is good.
public enum GuideCoverage {
    public static func problems(_ guide: Guide, screens: [String]) -> [String] {
        var out: [String] = []
        let covered = Set(guide.cards.map(\.screen))
        out += screens.filter { !covered.contains($0) }.map { "screen \($0) has no card" }
        let known = Set(screens)
        out += guide.cards.filter { !known.contains($0.screen) }.map { "card \($0.id): unknown screen \($0.screen)" }
        out += guide.cards.filter { !(3...5).contains($0.steps.count) }
            .map { "card \($0.id): \($0.steps.count) steps, needs 3-5" }
        out += guide.cards.filter { !$0.title.hasPrefix("How do I") }.map { #"card \#($0.id): title must start "How do I""# }
        out += guide.cards.filter { BuildNumber.parse($0.changed) == nil }
            .map { #"card \#($0.id): changed "\#($0.changed)" is not a build number"# }
        var seen = Set<String>(), dup: [String] = []
        for c in guide.cards where !seen.insert(c.id).inserted && !dup.contains(c.id) { dup.append(c.id) }
        out += dup.map { "duplicate card id \($0)" }
        return out
    }
}
