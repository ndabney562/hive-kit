import Foundation

/// Whether a repeated pattern is a UI/design element (`hive-design`) or shared logic/tooling (`hive-kit`).
public enum PatternCategory: String, Codable, Equatable, Hashable, Sendable {
    case interface
    case workflow
}

/// Target shared package that should own the pattern.
public enum TargetPackage: String, Codable, Equatable, Hashable, Sendable {
    case hiveDesign = "hive-design"
    case hiveKit = "hive-kit"
}

/// Whether apps should adopt something already in a shared package or extract a new shared component.
public enum ProposalAction: String, Codable, Equatable, Hashable, Sendable {
    case adoptExisting
    case extractNew
}

/// Estimated effort to unify the pattern across affected repositories.
public enum CostTier: String, Codable, Equatable, Hashable, Sendable {
    case low
    case medium
    case high

    var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

/// Quantified migration cost for consolidating a repeated pattern.
public struct MigrationCost: Codable, Equatable, Sendable {
    public var tier: CostTier
    public var affectedRepos: Int
    public var affectedFiles: Int
    public var estimatedLines: Int
    public var rationale: String

    public init(tier: CostTier, affectedRepos: Int, affectedFiles: Int, estimatedLines: Int, rationale: String) {
        self.tier = tier
        self.affectedRepos = affectedRepos
        self.affectedFiles = affectedFiles
        self.estimatedLines = estimatedLines
        self.rationale = rationale
    }

    public static func estimate(uses: [PatternUse], action: ProposalAction) -> MigrationCost {
        let repoCount = Set(uses.map(\.repo)).count
        let fileCount = Set(uses.map { "\($0.repo)/\($0.file)" }).count
        let lines = uses.reduce(0) { $0 + max(1, $1.lineCount) }

        let tier: CostTier
        if (fileCount <= 3 && lines <= 150) || (action == .adoptExisting && fileCount <= 5) {
            tier = .low
        } else if fileCount <= 8 && lines <= 450 {
            tier = .medium
        } else {
            tier = .high
        }

        let verb = action == .adoptExisting ? "adopt existing shared block" : "extract new shared API"
        let rationale = "\(repoCount) repo(s), \(fileCount) file(s), ~\(lines) lines (\(verb))"
        return MigrationCost(
            tier: tier,
            affectedRepos: repoCount,
            affectedFiles: fileCount,
            estimatedLines: lines,
            rationale: rationale
        )
    }
}

/// Concrete code location where a pattern or duplicated symbol appears.
public struct PatternUse: Codable, Equatable, Sendable {
    public var repo: String
    public var file: String
    public var line: Int
    public var symbol: String?
    public var lineCount: Int
    public var excerpt: String

    public init(repo: String, file: String, line: Int, symbol: String? = nil, lineCount: Int, excerpt: String) {
        self.repo = repo
        self.file = file
        self.line = line
        self.symbol = symbol
        self.lineCount = lineCount
        self.excerpt = excerpt
    }
}

/// Proposed shared implementation or adoption opportunity discovered across app repositories.
public struct PatternProposal: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var category: PatternCategory
    public var targetPackage: TargetPackage
    public var action: ProposalAction
    public var summary: String
    public var uses: [PatternUse]
    public var repoCount: Int
    public var fileCount: Int
    public var migrationCost: MigrationCost
    public var privacyBoundaryNote: String?

    public init(
        id: String,
        title: String,
        category: PatternCategory,
        targetPackage: TargetPackage,
        action: ProposalAction,
        summary: String,
        uses: [PatternUse],
        repoCount: Int,
        fileCount: Int,
        migrationCost: MigrationCost,
        privacyBoundaryNote: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.targetPackage = targetPackage
        self.action = action
        self.summary = summary
        self.uses = uses
        self.repoCount = repoCount
        self.fileCount = fileCount
        self.migrationCost = migrationCost
        self.privacyBoundaryNote = privacyBoundaryNote
    }
}

/// Repository root passed to `HivePattern.scan`.
public struct PatternRepo: Equatable, Sendable {
    public var name: String
    public var root: URL

    public init(name: String, root: URL) {
        self.name = name
        self.root = root
    }
}

/// Signature-based cross-app pattern rule evaluated on each Swift source file.
public struct PatternRule: Sendable {
    public var id: String
    public var title: String
    public var category: PatternCategory
    public var targetPackage: TargetPackage
    public var action: ProposalAction
    public var summary: String
    public var minRepos: Int
    public var skipRepos: Set<String>
    public var matcher: @Sendable (String) -> [(line: Int, excerpt: String)]

    public init(
        id: String,
        title: String,
        category: PatternCategory,
        targetPackage: TargetPackage,
        action: ProposalAction,
        summary: String,
        minRepos: Int = 2,
        skipRepos: Set<String> = [],
        matcher: @escaping @Sendable (String) -> [(line: Int, excerpt: String)]
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.targetPackage = targetPackage
        self.action = action
        self.summary = summary
        self.minRepos = minRepos
        self.skipRepos = skipRepos
        self.matcher = matcher
    }
}

/// #57 Pattern 96: detects repeated interface and workflow implementations across Hive apps, checks whether shared
/// packages already cover them, and estimates migration cost.
public enum HivePattern {
    private static let ignoredSymbols: Set<String> = [
        "CodingKeys", "Previews", "PreviewProvider", "AppModel", "ContentView", "Route",
    ]

    public static let defaultRules: [PatternRule] = [
        PatternRule(
            id: "json-userdefaults-store",
            title: "JSON-backed UserDefaults store",
            category: .workflow,
            targetPackage: .hiveKit,
            action: .adoptExisting,
            summary: "JSON models encoded straight into UserDefaults; use HiveKit's `JSONDefaultsStore` (since 1.29.0).",
            minRepos: 1,
            skipRepos: ["hive-kit", "HiveKit"]
        ) { source in
            let code = nonCommentLines(in: source)
            let hasDefaults = code.contains { $0.text.contains("UserDefaults") }
            let hasJSON = code.contains { $0.text.contains("JSONEncoder") || $0.text.contains("JSONDecoder") }
            guard hasDefaults, hasJSON, let first = code.first(where: { $0.text.contains("UserDefaults") }) else { return [] }
            return [(first.line, first.text)]
        },
        PatternRule(
            id: "json-file-store",
            title: "JSON file store in Application Support",
            category: .workflow,
            targetPackage: .hiveKit,
            action: .adoptExisting,
            summary: "Hand-rolled Application Support JSON files; use HiveKit's `JSONFileStore` (since 1.29.0).",
            minRepos: 1,
            skipRepos: ["hive-kit", "HiveKit"]
        ) { source in
            let code = nonCommentLines(in: source)
            let hasAppSupport = code.contains { $0.text.contains("applicationSupportDirectory") }
            let hasJSON = code.contains { $0.text.contains("JSONEncoder") || $0.text.contains("JSONDecoder") }
            guard hasAppSupport, hasJSON,
                  let first = code.first(where: { $0.text.contains("applicationSupportDirectory") }) else { return [] }
            return [(first.line, first.text)]
        },
        PatternRule(
            id: "raw-vertical-scrollview",
            title: "Raw vertical ScrollView instead of HMScroll",
            category: .interface,
            targetPackage: .hiveDesign,
            action: .adoptExisting,
            summary: "Vertical ScrollView allows sideways drift on iPhone; switch to hive-design's HMScroll.",
            minRepos: 1
        ) { source in
            nonCommentLines(in: source).compactMap { entry in
                guard !entry.text.contains("HMScroll") else { return nil }
                if matchesRegex(#"\bScrollView\s*\{"#, in: entry.text)
                    || matchesRegex(#"\bScrollView\s*\(\s*\.vertical\b"#, in: entry.text) {
                    return (entry.line, entry.text)
                }
                return nil
            }
        },
        PatternRule(
            id: "direct-urlsession-shared",
            title: "Direct URLSession.shared instead of HiveKit HTTPTransport",
            category: .workflow,
            targetPackage: .hiveKit,
            action: .adoptExisting,
            summary: "Direct URLSession.shared calls bypass HiveKit's HTTPTransport testability and ephemeral session defaults.",
            minRepos: 1,
            skipRepos: ["hive-kit", "HiveKit"]
        ) { source in
            nonCommentLines(in: source).compactMap { entry in
                entry.text.contains("URLSession.shared") ? (entry.line, entry.text) : nil
            }
        },
        PatternRule(
            id: "demo-temp-directory",
            title: "Ephemeral demo directory setup",
            category: .workflow,
            targetPackage: .hiveKit,
            action: .extractNew,
            summary: "Apps repeat temporaryDirectory.appendingPathComponent(\"demo-...\") fixture setup; share a demo storage helper.",
            minRepos: 2
        ) { source in
            nonCommentLines(in: source).compactMap { entry in
                entry.text.contains("temporaryDirectory.appendingPathComponent(\"demo-") ? (entry.line, entry.text) : nil
            }
        },
    ]

    public static func scan(
        repos: [PatternRepo],
        sharedPackages: [PatternRepo] = [],
        isolatedRepos: Set<String> = [],
        minRepos: Int = 2,
        rules: [PatternRule] = defaultRules
    ) -> [PatternProposal] {
        let effectiveMin = max(1, minRepos)
        let sharedSymbols = collectPublicSymbols(in: sharedPackages)

        struct SourceFile {
            let repo: String
            let relativePath: String
            let text: String
        }

        var allFiles: [SourceFile] = []
        for repo in repos {
            for (rel, text) in collectSwiftFiles(in: repo.root) {
                allFiles.append(SourceFile(repo: repo.name, relativePath: rel, text: text))
            }
        }

        var proposals: [PatternProposal] = []

        // 1. Signature rules
        for rule in rules {
            var ruleUses: [PatternUse] = []
            for file in allFiles where !rule.skipRepos.contains(file.repo) {
                let hits = rule.matcher(file.text)
                for hit in hits {
                    ruleUses.append(PatternUse(
                        repo: file.repo,
                        file: file.relativePath,
                        line: hit.line,
                        symbol: nil,
                        lineCount: 12,
                        excerpt: truncateExcerpt(hit.excerpt)
                    ))
                }
            }
            let repoCount = Set(ruleUses.map(\.repo)).count
            let threshold = rule.action == .adoptExisting ? rule.minRepos : max(rule.minRepos, effectiveMin)
            guard repoCount >= threshold else { continue }
            proposals.append(makeProposal(
                id: "rule:\(rule.id)",
                title: rule.title,
                category: rule.category,
                targetPackage: rule.targetPackage,
                action: rule.action,
                summary: rule.summary,
                uses: ruleUses,
                isolatedRepos: isolatedRepos
            ))
        }

        // 2. Repeated type declarations across repositories
        struct SymbolOccurrence {
            let use: PatternUse
            let isInterface: Bool
        }
        var bySymbol: [String: [SymbolOccurrence]] = [:]

        for file in allFiles {
            for decl in extractDeclarations(from: file.text) where !ignoredSymbols.contains(decl.name) {
                let use = PatternUse(
                    repo: file.repo,
                    file: file.relativePath,
                    line: decl.line,
                    symbol: decl.name,
                    lineCount: decl.lineCount,
                    excerpt: truncateExcerpt(decl.header)
                )
                bySymbol[decl.name, default: []].append(SymbolOccurrence(use: use, isInterface: decl.isInterface))
            }
        }

        for symbol in bySymbol.keys.sorted() {
            let occs = bySymbol[symbol] ?? []
            let uses = occs.map(\.use)
            let repoCount = Set(uses.map(\.repo)).count
            guard repoCount >= effectiveMin else { continue }

            let isInterface = occs.contains(where: \.isInterface)
            let category: PatternCategory = isInterface ? .interface : .workflow
            let targetPackage: TargetPackage = isInterface ? .hiveDesign : .hiveKit
            let owners = sharedSymbols[symbol] ?? []
            let alreadyShared = owners.contains { $0.mappedTarget == targetPackage || $0.mappedTarget == nil }
            let action: ProposalAction = alreadyShared ? .adoptExisting : .extractNew
            let summary = alreadyShared
                ? "`\(symbol)` already exists as a public declaration in \(targetPackage.rawValue); adopt the shared version across \(repoCount) repos."
                : "`\(symbol)` is implemented independently in \(repoCount) repos; extract a shared \(category.rawValue) component into \(targetPackage.rawValue)."

            proposals.append(makeProposal(
                id: "symbol:\(symbol)",
                title: "Shared `\(symbol)` \(category.rawValue)",
                category: category,
                targetPackage: targetPackage,
                action: action,
                summary: summary,
                uses: uses,
                isolatedRepos: isolatedRepos
            ))
        }

        return proposals.sorted { lhs, rhs in
            if lhs.repoCount != rhs.repoCount { return lhs.repoCount > rhs.repoCount }
            if lhs.action != rhs.action { return lhs.action == .adoptExisting }
            if lhs.migrationCost.tier.rank != rhs.migrationCost.tier.rank {
                return lhs.migrationCost.tier.rank < rhs.migrationCost.tier.rank
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    public static func renderMarkdown(_ proposals: [PatternProposal]) -> String {
        if proposals.isEmpty {
            return "# Pattern Report\n\nNo cross-app duplication or pending shared adoptions found.\n"
        }

        var lines: [String] = [
            "# Pattern Report",
            "",
            "- **Proposals:** \(proposals.count)",
        ]

        for p in proposals {
            lines.append("")
            lines.append("## \(p.title)")
            lines.append("- **Package:** `\(p.targetPackage.rawValue)` · **Category:** \(p.category.rawValue) · **Action:** `\(p.action.rawValue)` · **Cost:** `\(p.migrationCost.tier.rawValue)` (\(p.migrationCost.rationale))")
            lines.append("- **Why:** \(p.summary)")
            if let note = p.privacyBoundaryNote {
                lines.append("- **Privacy boundary:** \(note)")
            }
            lines.append("- **Uses (\(p.repoCount) repo(s), \(p.fileCount) file(s)):**")
            for u in p.uses {
                let sym = u.symbol.map { " (`\($0)`, \(u.lineCount)L)" } ?? ""
                lines.append("  - `\(u.repo)/\(u.file):\(u.line)`\(sym) — `\(u.excerpt)`")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private static func makeProposal(
        id: String,
        title: String,
        category: PatternCategory,
        targetPackage: TargetPackage,
        action: ProposalAction,
        summary: String,
        uses: [PatternUse],
        isolatedRepos: Set<String>
    ) -> PatternProposal {
        let sortedUses = uses.sorted {
            if $0.repo != $1.repo { return $0.repo < $1.repo }
            if $0.file != $1.file { return $0.file < $1.file }
            return $0.line < $1.line
        }
        let repoCount = Set(sortedUses.map(\.repo)).count
        let fileCount = Set(sortedUses.map { "\($0.repo)/\($0.file)" }).count
        let cost = MigrationCost.estimate(uses: sortedUses, action: action)
        let touchedIsolated = Set(sortedUses.map(\.repo)).intersection(isolatedRepos).sorted()
        let boundaryNote = touchedIsolated.isEmpty
            ? nil
            : "Build-time sharing only for \(touchedIsolated.joined(separator: ", ")): keep user/runtime data isolated."

        return PatternProposal(
            id: id,
            title: title,
            category: category,
            targetPackage: targetPackage,
            action: action,
            summary: summary,
            uses: sortedUses,
            repoCount: repoCount,
            fileCount: fileCount,
            migrationCost: cost,
            privacyBoundaryNote: boundaryNote
        )
    }

    private struct SharedSymbolOwner: Hashable {
        let packageName: String
        let mappedTarget: TargetPackage?
    }

    private struct SwiftDeclaration {
        let name: String
        let line: Int
        let lineCount: Int
        let isPublic: Bool
        let isInterface: Bool
        let header: String
    }

    private struct LexedLine {
        let line: Int
        let code: String
        let braceDelta: Int
        let sawOpenBrace: Bool
    }

    private static func mappedPackage(for repoName: String) -> TargetPackage? {
        let low = repoName.lowercased()
        if low == "hive-design" || low.contains("design") { return .hiveDesign }
        if low == "hive-kit" || low.contains("kit") { return .hiveKit }
        return nil
    }

    private static func collectPublicSymbols(in repos: [PatternRepo]) -> [String: Set<SharedSymbolOwner>] {
        var out: [String: Set<SharedSymbolOwner>] = [:]
        for repo in repos {
            let owner = SharedSymbolOwner(packageName: repo.name, mappedTarget: mappedPackage(for: repo.name))
            for (_, text) in collectSwiftFiles(in: repo.root) {
                for decl in extractDeclarations(from: text) where decl.isPublic {
                    out[decl.name, default: []].insert(owner)
                }
            }
        }
        return out
    }

    private static func collectSwiftFiles(in root: URL) -> [(String, String)] {
        let fm = FileManager.default
        var results: [(String, String)] = []
        var visitedDirs: Set<String> = []

        func shouldSkipDir(_ name: String) -> Bool {
            if name.hasPrefix(".") { return true }
            if [".build", "build", "DerivedData", "SourcePackages", "Tests", "release-evidence"].contains(name) { return true }
            return name.hasSuffix("Tests") || name.hasSuffix("UITests")
        }

        func walk(_ dir: URL, relPrefix: String) {
            let canonical = dir.resolvingSymlinksInPath().path
            guard visitedDirs.insert(canonical).inserted else { return }
            guard let children = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
                let rel = relPrefix.isEmpty ? name : "\(relPrefix)/\(name)"

                if isDir.boolValue {
                    if !shouldSkipDir(name) {
                        walk(child, relPrefix: rel)
                    }
                } else if name.hasSuffix(".swift"), name != "Package.swift",
                          let text = try? String(contentsOf: child, encoding: .utf8) {
                    results.append((rel, text))
                }
            }
        }

        walk(root, relPrefix: "")
        return results
    }

    private static func lexSwiftLines(in text: String) -> [LexedLine] {
        var blockDepth = 0
        var multilineHashes: Int? = nil
        var out: [LexedLine] = []

        for (idx, raw) in text.components(separatedBy: .newlines).enumerated() {
            let chars = Array(raw)
            var singleLineHashes: Int? = nil
            var escaped = false
            var codeChars: [Character] = []
            var braceDelta = 0
            var sawOpen = false
            var i = 0

            while i < chars.count {
                let c = chars[i]
                let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil

                if let closeHashes = multilineHashes {
                    if closeHashes == 0 {
                        if escaped {
                            escaped = false
                            i += 1
                            continue
                        }
                        if c == "\\" {
                            escaped = true
                            i += 1
                            continue
                        }
                    }
                    if matchesTripleQuoteClose(in: chars, at: i, hashes: closeHashes) {
                        multilineHashes = nil
                        escaped = false
                        i += 3 + closeHashes
                        continue
                    }
                    i += 1
                    continue
                }

                if blockDepth > 0 {
                    if c == "/" && next == "*" {
                        blockDepth += 1
                        i += 2
                        continue
                    }
                    if c == "*" && next == "/" {
                        blockDepth -= 1
                        i += 2
                        continue
                    }
                    i += 1
                    continue
                }

                if let strHashes = singleLineHashes {
                    if strHashes == 0 {
                        codeChars.append(c)
                        if escaped {
                            escaped = false
                        } else if c == "\\" {
                            escaped = true
                        } else if c == "\"" {
                            singleLineHashes = nil
                        }
                        i += 1
                        continue
                    }
                    if matchesSingleQuoteClose(in: chars, at: i, hashes: strHashes) {
                        for k in 0...strHashes {
                            codeChars.append(chars[i + k])
                        }
                        singleLineHashes = nil
                        i += 1 + strHashes
                        continue
                    }
                    codeChars.append(c)
                    i += 1
                    continue
                }

                if c == "/" && next == "/" {
                    break
                }
                if c == "/" && next == "*" {
                    blockDepth = 1
                    i += 2
                    continue
                }
                if c == "#" {
                    var hashes = 0
                    while i + hashes < chars.count && chars[i + hashes] == "#" {
                        hashes += 1
                    }
                    if matchesTripleQuoteOpen(in: chars, at: i + hashes) {
                        multilineHashes = hashes
                        escaped = false
                        i += hashes + 3
                        continue
                    }
                    if i + hashes < chars.count && chars[i + hashes] == "\"" {
                        for k in 0...hashes {
                            codeChars.append(chars[i + k])
                        }
                        singleLineHashes = hashes
                        escaped = false
                        i += hashes + 1
                        continue
                    }
                }
                if c == "\"" {
                    if matchesTripleQuoteOpen(in: chars, at: i) {
                        multilineHashes = 0
                        escaped = false
                        i += 3
                        continue
                    }
                    singleLineHashes = 0
                    escaped = false
                    codeChars.append(c)
                    i += 1
                    continue
                }
                if c == "{" {
                    braceDelta += 1
                    sawOpen = true
                } else if c == "}" {
                    braceDelta -= 1
                }
                codeChars.append(c)
                i += 1
            }

            let trimmed = String(codeChars).trimmingCharacters(in: .whitespaces)
            out.append(LexedLine(line: idx + 1, code: trimmed, braceDelta: braceDelta, sawOpenBrace: sawOpen))
        }
        return out
    }

    private static func matchesTripleQuoteOpen(in chars: [Character], at index: Int) -> Bool {
        index + 2 < chars.count
            && chars[index] == "\""
            && chars[index + 1] == "\""
            && chars[index + 2] == "\""
    }

    private static func matchesTripleQuoteClose(in chars: [Character], at index: Int, hashes: Int) -> Bool {
        guard index + 2 + hashes < chars.count,
              chars[index] == "\"",
              chars[index + 1] == "\"",
              chars[index + 2] == "\"" else {
            return false
        }
        for k in 0..<hashes {
            if chars[index + 3 + k] != "#" { return false }
        }
        return true
    }

    private static func matchesSingleQuoteClose(in chars: [Character], at index: Int, hashes: Int) -> Bool {
        guard index + hashes < chars.count, chars[index] == "\"" else {
            return false
        }
        for k in 1...hashes {
            if chars[index + k] != "#" { return false }
        }
        return true
    }

    private static func nonCommentLines(in text: String) -> [(line: Int, text: String)] {
        lexSwiftLines(in: text).compactMap { entry in
            entry.code.isEmpty ? nil : (entry.line, entry.code)
        }
    }

    private static func extractDeclarations(from text: String) -> [SwiftDeclaration] {
        let lexed = lexSwiftLines(in: text)
        let declPattern = #"^((?:(?:public|internal|private|fileprivate|open|package|final|nonisolated|@MainActor)\s+)*)(struct|class|actor|enum|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: declPattern, options: []) else { return [] }

        var declarations: [SwiftDeclaration] = []
        var braceDepth = 0

        for (idx, entry) in lexed.enumerated() {
            let depthAtLineStart = braceDepth
            braceDepth = max(0, braceDepth + entry.braceDelta)

            // Only examine top-level non-comment declarations so comments and inner helpers cannot skew scope.
            guard depthAtLineStart == 0, !entry.code.isEmpty else { continue }

            let code = entry.code
            let range = NSRange(code.startIndex..., in: code)
            guard let m = regex.firstMatch(in: code, range: range),
                  let modRange = Range(m.range(at: 1), in: code),
                  let nameRange = Range(m.range(at: 3), in: code),
                  let tailRange = Range(m.range(at: 4), in: code) else { continue }

            let modifierPrefix = String(code[modRange])
            let name = String(code[nameRange])
            let tail = String(code[tailRange])
            let lineCount = measureBlockLength(lexed: lexed, startIndex: idx)
            let isPublic = matchesRegex(#"\b(public|open)\b"#, in: modifierPrefix)
            let isViewConformance = matchesRegex(#":[^\{]*\b(View|ViewModifier)\b"#, in: tail)
            let hasViewSuffix = ["View", "Card", "Row", "Sheet", "Menu", "Button", "Banner", "Badge"]
                .contains { name.hasSuffix($0) }

            declarations.append(SwiftDeclaration(
                name: name,
                line: entry.line,
                lineCount: lineCount,
                isPublic: isPublic,
                isInterface: isViewConformance || hasViewSuffix,
                header: code
            ))
        }
        return declarations
    }

    private static func measureBlockLength(lexed: [LexedLine], startIndex: Int) -> Int {
        var depth = 0
        var seenOpen = false
        for i in startIndex..<lexed.count {
            depth += lexed[i].braceDelta
            if lexed[i].sawOpenBrace { seenOpen = true }
            if seenOpen && depth <= 0 {
                return max(1, i - startIndex + 1)
            }
        }
        return 1
    }

    private static func matchesRegex(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func truncateExcerpt(_ text: String, maxLength: Int = 96) -> String {
        let single = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard single.count > maxLength else { return single }
        let idx = single.index(single.startIndex, offsetBy: maxLength)
        return String(single[..<idx]) + "..."
    }
}
