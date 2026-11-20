import Foundation

/// Query parameters for searching across `HiveSearchIndex`.
public struct SearchQuery: Equatable, Sendable {
    public var text: String
    public var kinds: Set<SearchKind>?
    public var scopes: Set<String>?
    public var includeArchived: Bool
    public var limit: Int

    public init(
        text: String,
        kinds: Set<SearchKind>? = nil,
        scopes: Set<String>? = nil,
        includeArchived: Bool = true,
        limit: Int = 20
    ) {
        self.text = text
        self.kinds = kinds
        self.scopes = scopes
        self.includeArchived = includeArchived
        self.limit = limit
    }
}

/// Ranked result from `HiveSearchIndex`, carrying score, matched terms, and a focused snippet.
public struct SearchHit: Codable, Equatable, Sendable {
    public var item: SearchItem
    public var score: Double
    public var matchedTerms: [String]
    public var snippet: String

    public init(item: SearchItem, score: Double, matchedTerms: [String], snippet: String) {
        self.item = item
        self.score = score
        self.matchedTerms = matchedTerms
        self.snippet = snippet
    }
}

/// Unified search index combining workspace files, deliverables, notes, sources, examples, and Hive feeds
/// (Hive build order #50–#54: Shelf 4, Recall 22, Source 21, Example 95, Search 61).
public struct HiveSearchIndex: Sendable {
    private static let stopWords: Set<String> = [
        "the", "a", "an", "is", "was", "were", "are", "be", "why", "how", "what",
        "when", "where", "who", "to", "of", "in", "for", "on", "and", "or", "with",
        "it", "that", "this", "from", "by", "as", "at",
    ]

    public private(set) var items: [SearchItem] = []
    private var indexByID: [String: Int] = [:]

    public init(items: [SearchItem] = []) {
        add(items)
    }

    public mutating func add(_ newItems: [SearchItem]) {
        for item in newItems {
            if let existing = indexByID[item.id] {
                items[existing] = item
            } else {
                indexByID[item.id] = items.count
                items.append(item)
            }
        }
    }

    public mutating func add(deliverables: [ShelfDeliverable], scope: String = "personal") {
        add(deliverables.map { $0.searchItem(scope: scope) })
    }

    public mutating func add(sources: SourceRegistry, scope: String = "shared", driftedIDs: Set<String> = []) {
        add(sources.searchItems(scope: scope, driftedIDs: driftedIDs))
    }

    public mutating func add(examples: ExampleLibrary, scope: String = "shared") {
        add(examples.searchItems(scope: scope))
    }

    public mutating func add(voiceProfile: VoiceProfile, scope: String = "shared") {
        add(voiceProfile.exampleSearchItems(scope: scope))
    }

    /// Indexes decoded Hive feed summaries with `HiveLink` deep-link targets.
    public mutating func addFeed(
        tempo: TempoSummary? = nil,
        world: WorldSummary? = nil,
        score: ScoreSummary? = nil,
        business: BusinessSummary? = nil,
        jobs: JobsSummary? = nil,
        releases: ReleasesSummary? = nil,
        scope: String = "personal"
    ) {
        var batch: [SearchItem] = []

        if let tempo {
            for (role, task) in [("current", tempo.current), ("next", tempo.next)] {
                guard let task else { continue }
                let link = HiveLink.tempo(task: task.id)
                let timing = task.until.map { "until \($0)" } ?? task.at.map { "at \($0)" } ?? tempo.state
                batch.append(SearchItem(
                    id: "feed:tempo:\(role):\(task.id ?? task.title)",
                    kind: .task,
                    scope: scope,
                    title: task.title,
                    subtitle: "HiveTempo (\(role)) · \(timing)",
                    body: "\(task.title)\nDate: \(tempo.date) (\(tempo.done)/\(tempo.total) done, \(tempo.state))",
                    date: tempo.date,
                    freshness: .current,
                    tags: ["task", "hivetempo", role, tempo.state],
                    target: .hive(link),
                    metadata: ["role": role, "state": tempo.state]
                ))
            }
        }

        if let world {
            let pickOrder = Dictionary(uniqueKeysWithValues: world.pick.enumerated().map { ($1, $0 + 1) })
            for project in world.projects {
                let rank = pickOrder[project.id].map { "pick #\($0)" } ?? (project.paused ? "paused" : "tracked")
                let body = [project.reason, project.need.map { String(format: "need %.1f", $0) }, rank]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                batch.append(SearchItem(
                    id: "feed:world:project:\(project.id)",
                    kind: .project,
                    scope: scope,
                    title: project.name,
                    subtitle: "HiveWorld · \(rank)",
                    body: body.isEmpty ? project.name : body,
                    freshness: project.paused ? .archived : .current,
                    tags: ["project", "hiveworld", project.id],
                    target: .hive(.open(.world)),
                    metadata: ["projectID": project.id, "paused": "\(project.paused)"]
                ))
            }
        }

        if let score {
            for fix in score.topFixes {
                batch.append(SearchItem(
                    id: "feed:score:fix:\(fix.id)",
                    kind: .appRecord,
                    scope: scope,
                    title: fix.title,
                    subtitle: "HiveScore fix · \(fix.repo) (\(String(format: "%.1f", fix.points)) pts)",
                    body: "\(fix.title) in \(fix.repo) (worth \(String(format: "%.1f", fix.points)) points)",
                    freshness: .current,
                    tags: ["hivescore", "fix", fix.repo],
                    target: .hive(.open(.score)),
                    metadata: ["repo": fix.repo]
                ))
            }
            for repo in score.repos ?? [] {
                batch.append(SearchItem(
                    id: "feed:score:repo:\(repo.repo)",
                    kind: .project,
                    scope: scope,
                    title: repo.repo,
                    subtitle: "HiveScore · \(repo.score)/100",
                    body: "\(repo.repo) score \(repo.score) (HiveScore \(score.score) · \(score.word))",
                    freshness: .current,
                    tags: ["hivescore", repo.repo],
                    target: .hive(.open(.score)),
                    metadata: ["score": "\(repo.score)"]
                ))
            }
        }

        if let business {
            for route in business.routes {
                let earned = route.earnedUsd.map { String(format: "$%.2f", $0) } ?? "$0.00"
                batch.append(SearchItem(
                    id: "feed:business:route:\(route.name)",
                    kind: .appRecord,
                    scope: scope,
                    title: route.name,
                    subtitle: "Route · \(route.status) · \(earned)",
                    body: "\(route.name): status \(route.status), earned \(earned) (day \(business.day)/\(business.daysTotal))",
                    freshness: route.status.lowercased() == "paused" ? .archived : .current,
                    tags: ["business", "route", route.status],
                    target: .hive(.open(.score)),
                    metadata: ["status": route.status]
                ))
            }
            if let cp = business.nextCheckpoint {
                batch.append(SearchItem(
                    id: "feed:business:checkpoint:\(cp.date)",
                    kind: .appRecord,
                    scope: scope,
                    title: cp.title,
                    subtitle: "Checkpoint · \(cp.date)",
                    body: "\(cp.title) on \(cp.date)",
                    date: cp.date,
                    freshness: .current,
                    tags: ["business", "checkpoint"],
                    target: .hive(.open(.score))
                ))
            }
        }

        if let jobs {
            for job in jobs.jobs {
                let desc = job.cause ?? job.detail ?? job.output ?? job.status
                batch.append(SearchItem(
                    id: "feed:jobs:\(job.kind):\(job.name)",
                    kind: .appRecord,
                    scope: scope,
                    title: job.name,
                    subtitle: "Job (\(job.kind)) · \(job.status)",
                    body: "\(job.name) (\(job.kind)): \(job.status) — \(desc)",
                    date: job.lastOk?.at.prefix(10).description,
                    freshness: .current,
                    tags: ["job", job.kind, job.status, job.name],
                    target: .hive(.open(.score)),
                    metadata: ["status": job.status]
                ))
            }
        }

        if let releases {
            for rel in releases.releases {
                let changes = rel.changes?.joined(separator: "; ") ?? ""
                let body = "Build \(rel.build)" + (changes.isEmpty ? "" : "\nChanges: \(changes)")
                batch.append(SearchItem(
                    id: "feed:release:\(rel.app):\(rel.build)",
                    kind: .appRecord,
                    scope: scope,
                    title: "\(rel.app) build \(rel.build)",
                    subtitle: "Release · \(rel.testsPassed.map { "\($0) tests" } ?? "recorded")",
                    body: body,
                    date: ISO8601DateFormatter().string(from: rel.at).prefix(10).description,
                    freshness: .current,
                    tags: ["release", rel.app, rel.build],
                    target: .hive(.open(.score)),
                    metadata: ["app": rel.app, "build": rel.build]
                ))
            }
        }

        add(batch)
    }

    public func search(_ query: SearchQuery) -> [SearchHit] {
        let limit = max(0, query.limit)
        guard limit > 0 else { return [] }

        let filtered = items.filter { item in
            if let scopes = query.scopes, !scopes.contains(item.scope) { return false }
            if let kinds = query.kinds, !kinds.contains(item.kind) { return false }
            if !query.includeArchived, item.freshness == .archived { return false }
            return true
        }

        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = Self.queryTerms(trimmed)
        if terms.isEmpty {
            return filtered
                .sorted(by: Self.recencyOrder)
                .prefix(limit)
                .map { SearchHit(item: $0, score: Double($0.freshness.priority + 1), matchedTerms: [], snippet: Self.extractSnippet(from: $0.body, terms: [])) }
        }

        let phrase = trimmed.lowercased()
        var hits: [SearchHit] = []
        hits.reserveCapacity(filtered.count)

        for item in filtered {
            if let hit = Self.score(item: item, terms: terms, phrase: phrase) {
                hits.append(hit)
            }
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return Self.recencyOrder(a.item, b.item)
        }
        return Array(hits.prefix(limit))
    }

    private static func recencyOrder(_ a: SearchItem, _ b: SearchItem) -> Bool {
        if a.freshness.priority != b.freshness.priority {
            return a.freshness.priority > b.freshness.priority
        }
        let da = a.date ?? "", db = b.date ?? ""
        if da != db { return da > db }
        if a.title != b.title { return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
        return a.id < b.id
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func queryTerms(_ text: String) -> [String] {
        let raw = tokenize(text)
        guard !raw.isEmpty else { return [] }
        var seen: Set<String> = []
        let deduped = raw.filter { seen.insert($0).inserted }
        let meaningful = deduped.filter { !stopWords.contains($0) }
        return meaningful.isEmpty ? deduped : meaningful
    }

    private static func score(item: SearchItem, terms: [String], phrase: String) -> SearchHit? {
        let titleLower = item.title.lowercased()
        let subtitleLower = (item.subtitle ?? "").lowercased()
        let bodyLower = item.body.lowercased()
        let tagsLower = item.tags.map { $0.lowercased() }
        let metaLower = item.metadata.values.map { $0.lowercased() }.joined(separator: " ")

        let titleTokens = Set(tokenize(titleLower))
        let subtitleTokens = Set(tokenize(subtitleLower))
        let tagTokens = Set(tagsLower.flatMap(tokenize))
        let bodyTokenList = tokenize(bodyLower)
        var bodyCounts: [String: Int] = [:]
        for tok in bodyTokenList { bodyCounts[tok, default: 0] += 1 }

        var rawScore = 0.0
        var matched: [String] = []

        if phrase.count >= 3 {
            if titleLower.contains(phrase) { rawScore += 8.0 }
            if bodyLower.contains(phrase) { rawScore += 4.0 }
        }

        for term in terms {
            var termScore = 0.0

            if titleTokens.contains(term) {
                termScore += 5.0
            } else if titleLower.contains(term) {
                termScore += 2.5
            }

            if tagTokens.contains(term) {
                termScore += 3.5
            } else if tagsLower.contains(where: { $0.contains(term) }) {
                termScore += 1.5
            }

            if subtitleTokens.contains(term) {
                termScore += 2.5
            } else if subtitleLower.contains(term) {
                termScore += 1.0
            }

            if let count = bodyCounts[term] {
                termScore += 2.0 + min(2.0, Double(count - 1) * 0.4)
            } else if bodyLower.contains(term) {
                termScore += 0.8
            }

            if metaLower.contains(term) {
                termScore += 1.0
            }

            if termScore > 0 {
                matched.append(term)
                rawScore += termScore
            }
        }

        guard !matched.isEmpty else { return nil }
        let coverage = Double(matched.count) / Double(terms.count)
        let finalScore = (rawScore * (1.0 + coverage) * item.freshness.multiplier * 100).rounded() / 100
        let snippet = extractSnippet(from: item.body, terms: matched)
        return SearchHit(item: item, score: finalScore, matchedTerms: matched, snippet: snippet)
    }

    static func extractSnippet(from body: String, terms: [String], maxLength: Int = 280) -> String {
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }

        let chosen: String
        if terms.isEmpty {
            chosen = lines[0]
        } else {
            chosen = lines.max { lhs, rhs in
                matchDensity(lhs, terms: terms) < matchDensity(rhs, terms: terms)
            } ?? lines[0]
        }
        return truncate(chosen, maxLength: maxLength)
    }

    private static func matchDensity(_ line: String, terms: [String]) -> Int {
        let lower = line.lowercased()
        return terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let idx = text.index(text.startIndex, offsetBy: maxLength)
        let slice = text[..<idx]
        if let lastSpace = slice.lastIndex(of: " "), lastSpace > text.startIndex {
            return String(text[..<lastSpace]) + "..."
        }
        return String(slice) + "..."
    }
}
