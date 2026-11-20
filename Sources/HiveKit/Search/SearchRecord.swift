import Foundation

/// Pure-Foundation SHA-256 helper so `HiveKit` builds identically on macOS and Linux without extra imports.
public enum HiveSearchHash {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    public static func sha256Hex(_ data: Data) -> String {
        var bytes = [UInt8](data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while (bytes.count % 64) != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> shift) & 0xff))
        }

        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var w = [UInt32](repeating: 0, count: 64)

        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(bytes[j]) << 24) | (UInt32(bytes[j + 1]) << 16)
                    | (UInt32(bytes[j + 2]) << 8) | UInt32(bytes[j + 3])
            }
            for i in 16..<64 {
                let s0 = ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }

        return h.map { word in
            let hex = String(word, radix: 16)
            return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
        }.joined()
    }

    private static func ror(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }

    /// Normalizes line endings and outer whitespace for deterministic source fingerprinting.
    public static func normalizedSource(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func fingerprint(_ text: String) -> String {
        sha256Hex(normalizedSource(text))
    }

    /// Collapses whitespace and lowercases text for resilient passage-presence checks.
    static func normalizedPassage(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

/// Kind of record indexed by `HiveSearchIndex` (Hive build order #50–#54).
public enum SearchKind: String, Codable, CaseIterable, Hashable, Sendable {
    case shelf
    case recall
    case source
    case example
    case project
    case task
    case appRecord
}

/// Freshness state used to rank current guidance above archived decisions and flag drifted citations.
public enum SearchFreshness: String, Codable, Hashable, Sendable {
    case current
    case staleSource
    case draft
    case archived

    var priority: Int {
        switch self {
        case .current: 3
        case .staleSource: 2
        case .draft: 1
        case .archived: 0
        }
    }

    var multiplier: Double {
        switch self {
        case .current: 1.25
        case .staleSource: 1.0
        case .draft: 0.9
        case .archived: 0.65
        }
    }
}

/// Original location of an indexed item so callers can open it in its owning app, editor, or browser.
public struct SearchTarget: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case hiveLink
        case file
        case web
    }

    public var kind: Kind
    public var value: String
    public var line: Int?

    public init(kind: Kind, value: String, line: Int? = nil) {
        self.kind = kind
        self.value = value
        self.line = line
    }

    public static func hive(_ link: HiveLink) -> SearchTarget {
        SearchTarget(kind: .hiveLink, value: link.url.absoluteString)
    }

    public static func file(_ path: String, line: Int? = nil) -> SearchTarget {
        SearchTarget(kind: .file, value: path, line: line)
    }

    public static func web(_ url: String) -> SearchTarget {
        SearchTarget(kind: .web, value: url)
    }

    public var hiveLink: HiveLink? {
        guard kind == .hiveLink, let url = URL(string: value) else { return nil }
        return HiveLink.parse(url)
    }

    public static func parseReference(_ raw: String) -> SearchTarget {
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return .web(raw)
        }
        if let colon = raw.lastIndex(of: ":"),
           let line = Int(raw[raw.index(after: colon)...]),
           line > 0,
           colon > raw.startIndex {
            return .file(String(raw[..<colon]), line: line)
        }
        return .file(raw)
    }
}

/// Unified searchable item produced by scanners, registries, libraries, and Hive feeds.
public struct SearchItem: Codable, Equatable, Sendable {
    public var id: String
    public var kind: SearchKind
    public var scope: String
    public var title: String
    public var subtitle: String?
    public var body: String
    public var date: String?
    public var freshness: SearchFreshness
    public var tags: [String]
    public var target: SearchTarget
    public var relatedTargets: [SearchTarget]
    public var metadata: [String: String]

    public init(
        id: String,
        kind: SearchKind,
        scope: String = "personal",
        title: String,
        subtitle: String? = nil,
        body: String,
        date: String? = nil,
        freshness: SearchFreshness = .current,
        tags: [String] = [],
        target: SearchTarget,
        relatedTargets: [SearchTarget] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
        self.freshness = freshness
        self.tags = tags
        self.target = target
        self.relatedTargets = relatedTargets
        self.metadata = metadata
    }
}

/// #50 Shelf 4: deliverable record with preview path, approval status, caption, and usage history.
public struct ShelfDeliverable: Codable, Equatable, Sendable {
    public var id: String?
    public var slug: String
    public var title: String
    public var project: String
    public var status: String
    public var previewPath: String?
    public var captionText: String?
    public var captionPath: String?
    public var usageHistory: [String]
    public var date: String?
    public var directoryPath: String
    public var relatedPaths: [String]

    public init(
        slug: String,
        title: String,
        project: String,
        status: String,
        previewPath: String? = nil,
        captionText: String? = nil,
        captionPath: String? = nil,
        usageHistory: [String] = [],
        date: String? = nil,
        directoryPath: String,
        relatedPaths: [String] = [],
        id: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.project = project
        self.status = status
        self.previewPath = previewPath
        self.captionText = captionText
        self.captionPath = captionPath
        self.usageHistory = usageHistory
        self.date = date
        self.directoryPath = directoryPath
        self.relatedPaths = relatedPaths
    }

    public func searchItem(scope: String = "personal") -> SearchItem {
        let primary = (previewPath?.isEmpty == false) ? SearchTarget.file(previewPath!) : SearchTarget.file(directoryPath)
        var related: [SearchTarget] = []
        var seen: Set<String> = [primary.value]
        for path in [directoryPath] + (captionPath.map { [$0] } ?? []) + relatedPaths where !path.isEmpty {
            if seen.insert(path).inserted {
                related.append(.file(path))
            }
        }

        let lowerStatus = status.lowercased()
        let isDraft = lowerStatus.contains("draft")
            || lowerStatus.contains("not-published")
            || lowerStatus.contains("not published")
            || lowerStatus.contains("unapproved")
            || lowerStatus.contains("pending")

        var bodyParts: [String] = ["Status: \(status)"]
        if let captionText, !captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyParts.append("Caption: \(captionText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !usageHistory.isEmpty {
            bodyParts.append("Usage: \(usageHistory.joined(separator: "; "))")
        }
        if let previewPath, !previewPath.isEmpty {
            bodyParts.append("Preview: \(previewPath)")
        }

        var meta: [String: String] = [
            "slug": slug,
            "project": project,
            "status": status,
            "usageCount": "\(usageHistory.count)",
        ]
        if let previewPath, !previewPath.isEmpty { meta["preview"] = previewPath }
        if let captionPath, !captionPath.isEmpty { meta["captionPath"] = captionPath }

        let itemID = id ?? "shelf:\(project):\(slug)\(date.map { ":\($0)" } ?? "")"
        return SearchItem(
            id: itemID,
            kind: .shelf,
            scope: scope,
            title: title,
            subtitle: "\(project) · \(status)",
            body: bodyParts.joined(separator: "\n"),
            date: date,
            freshness: isDraft ? .draft : .current,
            tags: ["shelf", slug, project, status],
            target: primary,
            relatedTargets: related,
            metadata: meta
        )
    }
}

/// #52 Source 21: factual claim linked to its source, supporting passage, access date, and usage sites.
public struct SourceClaim: Codable, Equatable, Sendable {
    public var id: String
    public var claim: String
    public var source: String
    public var passage: String
    public var accessed: String
    public var usedIn: [String]
    public var sourceFingerprint: String?

    public init(
        id: String,
        claim: String,
        source: String,
        passage: String,
        accessed: String,
        usedIn: [String] = [],
        sourceFingerprint: String? = nil
    ) {
        self.id = id
        self.claim = claim
        self.source = source
        self.passage = passage
        self.accessed = accessed
        self.usedIn = usedIn
        self.sourceFingerprint = sourceFingerprint
    }
}

/// Reported when a claim's underlying source is unreadable, changed, or no longer supports the recorded passage.
public struct SourceDrift: Codable, Equatable, Sendable {
    public var claimID: String
    public var claim: String
    public var source: String
    public var reason: String

    public init(claimID: String, claim: String, source: String, reason: String) {
        self.claimID = claimID
        self.claim = claim
        self.source = source
        self.reason = reason
    }
}

/// Persistent JSON registry of factual claims and source citations.
public struct SourceRegistry: Codable, Equatable, Sendable {
    public var schema = 1
    public var claims: [SourceClaim]

    public init(claims: [SourceClaim] = []) {
        self.claims = claims
    }

    public static func decode(_ data: Data) throws -> SourceRegistry {
        try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public mutating func upsert(_ claim: SourceClaim) {
        claims.removeAll { $0.id == claim.id }
        claims.append(claim)
    }

    public func checkDrift(using fetchText: (String) -> String?) -> [SourceDrift] {
        var drifts: [SourceDrift] = []
        for entry in claims {
            guard let text = fetchText(entry.source) else {
                drifts.append(SourceDrift(claimID: entry.id, claim: entry.claim, source: entry.source, reason: "source unreadable"))
                continue
            }
            let normalizedDoc = HiveSearchHash.normalizedPassage(text)
            let normalizedQuote = HiveSearchHash.normalizedPassage(entry.passage)
            let passageMatches = normalizedQuote.isEmpty || normalizedDoc.contains(normalizedQuote)

            if let expectedHash = entry.sourceFingerprint {
                let currentHash = HiveSearchHash.fingerprint(text)
                if currentHash != expectedHash {
                    let reason = passageMatches
                        ? "source changed (supporting passage still present)"
                        : "source changed and supporting passage not found"
                    drifts.append(SourceDrift(claimID: entry.id, claim: entry.claim, source: entry.source, reason: reason))
                    continue
                }
            }

            if !passageMatches {
                drifts.append(SourceDrift(claimID: entry.id, claim: entry.claim, source: entry.source, reason: "supporting passage not found in source"))
            }
        }
        return drifts
    }

    public func searchItems(scope: String = "shared", driftedIDs: Set<String> = []) -> [SearchItem] {
        claims.map { c in
            let isDrifted = driftedIDs.contains(c.id)
            let target = SearchTarget.parseReference(c.source)
            let related = c.usedIn.map(SearchTarget.parseReference)
            var body = "Claim: \(c.claim)\nSource: \(c.source)\nAccessed: \(c.accessed)"
            if !c.passage.isEmpty { body += "\nPassage: \(c.passage)" }
            if !c.usedIn.isEmpty { body += "\nUsed in: \(c.usedIn.joined(separator: ", "))" }
            if isDrifted { body += "\nStatus: source changed or passage missing" }

            return SearchItem(
                id: "source:\(c.id)",
                kind: .source,
                scope: scope,
                title: c.claim,
                subtitle: "Accessed \(c.accessed) · \(c.source)",
                body: body,
                date: c.accessed,
                freshness: isDrifted ? .staleSource : .current,
                tags: ["source"] + (isDrifted ? ["drifted"] : []),
                target: target,
                relatedTargets: related,
                metadata: [
                    "source": c.source,
                    "accessed": c.accessed,
                    "usedIn": c.usedIn.joined(separator: ", "),
                ]
            )
        }
    }
}

/// #53 Example 95: curated example of high-quality work with why it succeeded.
public struct ApprovedExample: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var category: String
    public var content: String
    public var whyItWorks: String
    public var approved: String
    public var tags: [String]
    public var sourcePath: String?

    public init(
        id: String,
        title: String,
        category: String,
        content: String,
        whyItWorks: String,
        approved: String,
        tags: [String] = [],
        sourcePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.content = content
        self.whyItWorks = whyItWorks
        self.approved = approved
        self.tags = tags
        self.sourcePath = sourcePath
    }
}

/// Persistent JSON collection of approved examples.
public struct ExampleLibrary: Codable, Equatable, Sendable {
    public var schema = 1
    public var examples: [ApprovedExample]

    public init(examples: [ApprovedExample] = []) {
        self.examples = examples
    }

    public static func decode(_ data: Data) throws -> ExampleLibrary {
        try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public mutating func add(_ example: ApprovedExample) {
        examples.removeAll { $0.id == example.id }
        examples.append(example)
    }

    public func searchItems(scope: String = "shared") -> [SearchItem] {
        examples.map { e in
            let target: SearchTarget = e.sourcePath.map { SearchTarget.parseReference($0) }
                ?? .file("example:\(e.id)")
            return SearchItem(
                id: "example:\(e.id)",
                kind: .example,
                scope: scope,
                title: e.title,
                subtitle: "\(e.category) · approved \(e.approved)",
                body: "\(e.content)\nWhy it works: \(e.whyItWorks)",
                date: e.approved,
                freshness: .current,
                tags: ["example", e.category] + e.tags,
                target: target,
                metadata: ["category": e.category, "whyItWorks": e.whyItWorks]
            )
        }
    }
}

extension VoiceProfile {
    /// Exposes approved examples from a `VoiceProfile` directly to `HiveSearchIndex`.
    public func exampleSearchItems(scope: String = "shared") -> [SearchItem] {
        examples.enumerated().map { idx, example in
            let body = example.note.map { "\(example.text)\nWhy it works: \($0)" } ?? example.text
            return SearchItem(
                id: "voice-example:\(name):\(idx)",
                kind: .example,
                scope: scope,
                title: "\(name) example \(idx + 1)",
                subtitle: example.note ?? usedFor,
                body: body,
                date: example.approved,
                freshness: .current,
                tags: ["example", "voice", name] + tone,
                target: .file("voice-profile:\(name)"),
                metadata: ["profile": name, "usedFor": usedFor]
            )
        }
    }
}
