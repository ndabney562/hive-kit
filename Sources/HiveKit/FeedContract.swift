import Foundation

/// Hive build order #11 (Contract 56): does each app's published feed file match what its readers decode?
/// The contract is the reader's own `Decodable` type, so it can't drift from the apps: a file passes when the type
/// the apps use reads it. Problems come back as sentences ("summary.income.month: missing"), so HiveScore can show
/// them and a publisher can check a new file first (`hive-feed-check <app> <file>`) before a schema change ships.
public enum FeedContract {
    /// One reader's expectation of one feed file.
    public struct Contract: Sendable {
        public var app: String
        /// The Swift type the readers decode, for the message.
        public var reader: String
        let check: @Sendable (Data) -> [String]

        public init<S: Decodable & Sendable>(app: String, _ type: S.Type) {
            self.app = app
            self.reader = String(describing: type)
            self.check = { data in FeedContract.problems(data, app: app, as: type) }
        }
    }

    /// The feeds with a reader in hive-kit. An app adds its own (HiveScore: `iphone` with PhoneSummary).
    public static let known: [Contract] = [
        Contract(app: "hivemind", HiveMindSummary.self),
        Contract(app: "hive-tempo", TempoSummary.self),
        Contract(app: "health-score", ScoreSummary.self),
        Contract(app: "hiveworld", WorldSummary.self),
        Contract(app: "ai-business-db", BusinessSummary.self),
        Contract(app: "releases", ReleasesSummary.self),
        Contract(app: "ideas", IdeasSummary.self),
        Contract(app: "jobs", JobsSummary.self),
        Contract(app: "tools", ToolsSummary.self),
    ]

    /// Every way `data` fails the envelope rules (docs/hive-feed.md) or the reader type; empty when it passes.
    public static func problems<S: Decodable & Sendable>(_ data: Data, app: String, as type: S.Type) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["not a JSON object"]
        }
        var out: [String] = []
        if data.count > 64 * 1024 { out.append("over 64 KB (\(data.count / 1024) KB)") }
        guard json["schema"] as? Int == HiveFeed.schema else {
            return out + ["schema is \(json["schema"].map { "\($0)" } ?? "missing"), readers know \(HiveFeed.schema)"]
        }
        if let named = json["app"] as? String, named != app { out.append("app is \"\(named)\", the file is \(app).json") }
        // Checked by name: a bad date comes back from the decoder with no field in its path.
        let written = json["written_at"] as? String ?? ""
        if written.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$"#, options: .regularExpression) == nil {
            return out + ["written_at: not UTC like 2026-11-08T19:00:00Z"]
        }
        if !((json["stale_after_minutes"] as? Int).map { $0 > 0 } ?? false) {
            out.append("stale_after_minutes: not a whole number above 0")
        }
        do {
            _ = try HiveFeed.decode(data, as: type)
        } catch let error as DecodingError {
            out.append(words(error))
        } catch {
            out.append("unreadable: \(error)")
        }
        return out
    }

    /// A DecodingError as a sentence with its JSON path in the feed's own snake_case names.
    static func words(_ error: DecodingError) -> String {
        func path(_ keys: [any CodingKey], _ last: (any CodingKey)? = nil) -> String {
            let all = keys + (last.map { [$0] } ?? [])
            guard !all.isEmpty else { return "the file" }
            return all.map { key in key.intValue.map { "[\($0)]" } ?? "." + snake(key.stringValue) }
                .joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error {
        case .keyNotFound(let key, let c): return "\(path(c.codingPath, key)): missing"
        case .valueNotFound(let type, let c): return "\(path(c.codingPath)): null, readers need \(name(type))"
        case .typeMismatch(let type, let c): return "\(path(c.codingPath)): not \(name(type))"
        case .dataCorrupted(let c): return "\(path(c.codingPath)): \(c.debugDescription)"
        @unknown default: return "unreadable"
        }
    }

    static func name(_ type: Any.Type) -> String {
        switch String(describing: type) {
        case "Int", "Double", "Float": return "a number"
        case "String": return "text"
        case "Bool": return "true or false"
        case let t where t.hasPrefix("Array"): return "a list"
        case let t where t.hasPrefix("Dictionary"): return "an object"
        default: return "an object"
        }
    }

    /// `topFixes` back to the feed's `top_fixes` (the reader decodes with convertFromSnakeCase).
    static func snake(_ s: String) -> String {
        s.reduce(into: "") { out, c in
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
    }

    public struct Result: Equatable, Sendable {
        public var app: String
        public var reader: String
        public var problems: [String]
    }

    /// Every contract's feed, read the way the apps read it. A file that doesn't exist yet is not a problem; one
    /// that can't be fetched is skipped (offline is not a contract break). Only failing feeds come back.
    public static func check(_ fetch: @escaping HiveFeedReader.Fetch, contracts: [Contract] = known) async -> [Result] {
        var out: [Result] = []
        for c in contracts {
            guard let data = try? await fetch(c.app) else { continue }
            let problems = c.check(data)
            if !problems.isEmpty { out.append(Result(app: c.app, reader: c.reader, problems: problems)) }
        }
        return out
    }
}

extension HiveFeedReader {
    /// FeedContract.check over this reader's files.
    public func contractProblems(extra: [FeedContract.Contract] = []) async -> [FeedContract.Result] {
        await FeedContract.check(fetch, contracts: FeedContract.known + extra)
    }
}
