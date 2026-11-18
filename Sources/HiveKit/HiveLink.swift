import Foundation

/// A link to one place in a Hive app (Hive build order #32, Link 62): build it in one app, open it in another, and
/// say what happened when the app or the item isn't there. One table of routes, so every sender and receiver agrees.
///
/// Routes (scheme = the app's lowercased name, as `HiveApp.url`):
/// - `<app>://`                 the app's first screen, for every Hive app
/// - `hivetempo://today`        HiveTempo's Today
/// - `hivetempo://task/<id>`    one task (ids end with their day: `<slug>-YYYY-MM-DD`)
public enum HiveLink: Equatable, Hashable, Sendable {
    case open(HiveApp)
    case tempoToday
    case tempoTask(String)

    public var app: HiveApp {
        switch self {
        case .open(let app): app
        case .tempoToday, .tempoTask: .tempo
        }
    }

    public var url: URL {
        let scheme = app.name.lowercased()
        return switch self {
        case .open: URL(string: "\(scheme)://")!
        case .tempoToday: URL(string: "\(scheme)://today")!
        // An id that isn't one (spaces, slashes) never reaches a URL: the link opens Today instead of crashing.
        case .tempoTask(let id) where Self.isID(id): URL(string: "\(scheme)://task/\(id)")!
        case .tempoTask: URL(string: "\(scheme)://today")!
        }
    }

    /// The link for a task id from the feed: that task, or Today when there is no id or it isn't a valid one.
    public static func tempo(task id: String?) -> HiveLink {
        guard let id, isID(id) else { return .tempoToday }
        return .tempoTask(id)
    }

    /// What the link opens, in words ("HiveTempo › task reply-comments-2026-11-18").
    public var place: String {
        switch self {
        case .open(let app): app.name
        case .tempoToday: "HiveTempo › Today"
        case .tempoTask(let id): "HiveTempo › task \(id)"
        }
    }

    /// The link a URL names, or nil when it is not a Hive link this table knows (wrong scheme, unknown route, or an
    /// id with characters an id never has). A receiver opens its first screen for nil.
    public static func parse(_ url: URL) -> HiveLink? {
        guard let scheme = url.scheme?.lowercased(),
              let app = HiveApp.allCases.first(where: { $0.name.lowercased() == scheme }) else { return nil }
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.query == nil, c.fragment == nil
        else { return nil }
        let parts = ([c.host ?? ""] + c.path.split(separator: "/").map(String.init)).filter { !$0.isEmpty }
        if parts.isEmpty { return .open(app) }
        guard app == .tempo else { return nil }
        switch (parts.first, parts.count) {
        case ("today", 1): return .tempoToday
        case ("task", 2) where isID(parts[1]): return .tempoTask(parts[1])
        default: return nil
        }
    }

    /// Lowercase letters, digits and dashes, 1-120 characters: what the planner's ids are made of.
    public static func isID(_ s: String) -> Bool {
        (1...120).contains(s.count) && s.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    /// The sender's fallback when the system could not open the link: the app is not on this device.
    public var notInstalled: String {
        "\(app.name) isn't on this iPhone. Install it from TestFlight, then tap again."
    }

    /// The receiver's fallback when the item is gone (a task no longer in the plan): what it shows instead.
    public var missing: String {
        switch self {
        case .tempoTask: "That task isn't in today's or tomorrow's plan any more, so here is Today."
        case .open, .tempoToday: ""
        }
    }

    /// One example of every route, for `hive-link-check` and the tests.
    public static let examples: [HiveLink] = HiveApp.allCases.map { .open($0) }
        + [.tempoToday, .tempoTask("reply-comments-2026-11-18")]
}
