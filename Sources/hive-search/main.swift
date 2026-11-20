import Foundation
import HiveKit

// hive-search (Hive build order #50–#54: Shelf 4, Recall 22, Source 21, Example 95, Search 61).
// Usage:
//   hive-search query <text> [--kind <k>]... [--root <dir-or-file>]... [--feed-dir <dir>]
//                            [--sources <file.json>] [--examples <file.json>] [--voice <profile.json>]
//                            [--scope <name>]... [--current-only] [--limit N] [--json]
//   hive-search shelf <text> [...]
//   hive-search recall <text> [...]
//   hive-search source check <registry.json> [--json]
//   hive-search source add <registry.json> --id <id> --claim <text> --source <src> --passage <text>
//                          [--accessed YYYY-MM-DD] [--used-in <where>]... [--fingerprint-file <path>]
//   hive-search example add <library.json> --id <id> --title <t> --category <cat> --content <text> --why <note>
//                           [--approved YYYY-MM-DD] [--tags a,b] [--source <path>]
//   hive-search example find <text> --examples <library.json> [--voice <profile.json>] [--category <cat>] [--limit N] [--json]
// Exit: 0 ok, 1 drift found (source check), 2 usage or file problem.

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

private let usage = "usage: hive-search query|shelf|recall|source|example ... (see Sources/hive-search/main.swift)"

private func takeOption(_ name: String, from args: inout [String]) -> String? {
    guard let idx = args.firstIndex(of: name) else { return nil }
    guard idx + 1 < args.count else { fail("hive-search: \(name) needs a value") }
    let value = args[idx + 1]
    args.removeSubrange(idx...(idx + 1))
    return value
}

private func takeRepeated(_ name: String, from args: inout [String]) -> [String] {
    var out: [String] = []
    while let value = takeOption(name, from: &args) {
        out.append(value)
    }
    return out
}

private func takeFlag(_ name: String, from args: inout [String]) -> Bool {
    guard let idx = args.firstIndex(of: name) else { return false }
    args.remove(at: idx)
    return true
}

private func expandPath(_ raw: String) -> URL {
    URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
}

private func isoToday() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
}

private func loadRegistry(at url: URL, allowMissing: Bool = false) -> SourceRegistry {
    if !FileManager.default.fileExists(atPath: url.path) {
        if allowMissing { return SourceRegistry() }
        fail("hive-search: file not found: \(url.path)")
    }
    guard let data = try? Data(contentsOf: url) else { fail("hive-search: can't read \(url.path)") }
    do { return try SourceRegistry.decode(data) }
    catch { fail("hive-search: invalid source registry \(url.path): \(error)") }
}

private func loadExamples(at url: URL, allowMissing: Bool = false) -> ExampleLibrary {
    if !FileManager.default.fileExists(atPath: url.path) {
        if allowMissing { return ExampleLibrary() }
        fail("hive-search: file not found: \(url.path)")
    }
    guard let data = try? Data(contentsOf: url) else { fail("hive-search: can't read \(url.path)") }
    do { return try ExampleLibrary.decode(data) }
    catch { fail("hive-search: invalid example library \(url.path): \(error)") }
}

private func runSearch(presetKinds: Set<SearchKind>?, categoryFilter: String? = nil, args initialArgs: [String]) {
    var args = initialArgs
    let asJSON = takeFlag("--json", from: &args)
    let currentOnly = takeFlag("--current-only", from: &args)
    let limit = takeOption("--limit", from: &args).map {
        Int($0) ?? { fail("hive-search: --limit takes an integer") }()
    } ?? 20

    let kindArgs = takeRepeated("--kind", from: &args)
    var kinds = presetKinds
    if !kindArgs.isEmpty {
        var parsed: Set<SearchKind> = kinds ?? []
        for raw in kindArgs {
            guard let k = SearchKind(rawValue: raw) else {
                fail("hive-search: unknown --kind '\(raw)' (valid: \(SearchKind.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            parsed.insert(k)
        }
        kinds = parsed
    }

    let roots = takeRepeated("--root", from: &args).map(expandPath)
    let feedDirs = takeRepeated("--feed-dir", from: &args).map(expandPath)
    let sourceFiles = takeRepeated("--sources", from: &args).map(expandPath)
    let exampleFiles = takeRepeated("--examples", from: &args).map(expandPath)
    let voiceFiles = takeRepeated("--voice", from: &args).map(expandPath)
    let scopeArgs = takeRepeated("--scope", from: &args)
    let scopes: Set<String>? = scopeArgs.isEmpty ? nil : Set(scopeArgs)

    if let badFlag = args.first(where: { $0.hasPrefix("-") }) {
        fail("hive-search: unknown option \(badFlag)")
    }
    let queryText = args.joined(separator: " ")

    var index = HiveSearchIndex()
    if !roots.isEmpty {
        index.add(HiveWorkspaceScanner.scan(roots: roots))
    }
    for dir in feedDirs {
        index.add(HiveWorkspaceScanner.scanFeeds(directory: dir))
    }
    for file in sourceFiles {
        index.add(sources: loadRegistry(at: file))
    }
    for file in exampleFiles {
        index.add(examples: loadExamples(at: file))
    }
    for file in voiceFiles {
        guard let data = try? Data(contentsOf: file) else { fail("hive-search: can't read \(file.path)") }
        do {
            let profile = try VoiceProfile.decode(data)
            index.add(voiceProfile: profile)
        } catch {
            fail("hive-search: invalid voice profile \(file.path): \(error)")
        }
    }

    let hits = index.search(SearchQuery(
        text: queryText,
        kinds: kinds,
        scopes: scopes,
        category: categoryFilter,
        includeArchived: !currentOnly,
        limit: limit
    ))

    if asJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(hits) else { fail("hive-search: failed to encode results") }
        print(String(decoding: data, as: UTF8.self))
        return
    }

    if hits.isEmpty {
        print("No matches.")
        return
    }
    for (idx, hit) in hits.enumerated() {
        let item = hit.item
        let lineSuffix = item.target.line.map { ":\($0)" } ?? ""
        let dateStr = item.date.map { " [\($0)]" } ?? ""
        print("\(idx + 1). [\(item.kind.rawValue) · \(item.freshness.rawValue)] \(item.title)\(dateStr)  (score \(hit.score))")
        if let sub = item.subtitle, !sub.isEmpty { print("   \(sub)") }
        print("   target: \(item.target.value)\(lineSuffix)")
        if !hit.snippet.isEmpty { print("   \(hit.snippet)") }
    }
}

private func runSource(args initialArgs: [String]) {
    var args = initialArgs
    guard !args.isEmpty else { fail("usage: hive-search source check|add <registry.json> ...") }
    let sub = args.removeFirst()

    switch sub {
    case "check":
        let asJSON = takeFlag("--json", from: &args)
        guard args.count == 1 else { fail("usage: hive-search source check <registry.json> [--json]") }
        let url = expandPath(args[0])
        let registry = loadRegistry(at: url)
        let baseDir = url.deletingLastPathComponent()

        let localClaims = registry.claims.filter {
            SearchTarget.parseReference($0.source).kind == .file
        }
        let remoteSkipped = registry.claims.count - localClaims.count
        let localRegistry = SourceRegistry(claims: localClaims)

        let drifts = localRegistry.checkDrift { sourceRef in
            let cleanPath = SearchTarget.parseReference(sourceRef).value
            let fileURL: URL = cleanPath.hasPrefix("/") || cleanPath.hasPrefix("~")
                ? expandPath(cleanPath)
                : baseDir.appendingPathComponent(cleanPath)
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        if asJSON {
            struct Report: Encodable {
                let checkedLocal: Int
                let skippedRemote: Int
                let ok: Bool
                let drifts: [SourceDrift]
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let report = Report(checkedLocal: localClaims.count, skippedRemote: remoteSkipped, ok: drifts.isEmpty, drifts: drifts)
            guard let data = try? enc.encode(report) else { fail("hive-search: JSON encode failed") }
            print(String(decoding: data, as: UTF8.self))
        } else if drifts.isEmpty {
            print("ok: \(localClaims.count) local source(s) verified" + (remoteSkipped > 0 ? " (\(remoteSkipped) remote skipped)" : ""))
        } else {
            print("drift: \(drifts.count) issue(s) across \(localClaims.count) local source(s)")
            for d in drifts {
                print("  - [\(d.claimID)] \(d.reason): \(d.source) (\(d.claim))")
            }
        }
        exit(drifts.isEmpty ? 0 : 1)

    case "add":
        guard !args.isEmpty else { fail("usage: hive-search source add <registry.json> --id ... --claim ... --source ... --passage ...") }
        let path = expandPath(args.removeFirst())
        guard let id = takeOption("--id", from: &args),
              let claim = takeOption("--claim", from: &args),
              let source = takeOption("--source", from: &args),
              let passage = takeOption("--passage", from: &args) else {
            fail("hive-search source add requires --id, --claim, --source, and --passage")
        }
        let accessed = takeOption("--accessed", from: &args) ?? isoToday()
        let usedIn = takeRepeated("--used-in", from: &args)
        let fingerprintPath = takeOption("--fingerprint-file", from: &args)
        let fingerprint: String? = fingerprintPath.map { raw in
            let url = expandPath(raw)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                fail("hive-search: can't read --fingerprint-file \(raw)")
            }
            return HiveSearchHash.fingerprint(text)
        }

        var registry = loadRegistry(at: path, allowMissing: true)
        registry.upsert(SourceClaim(
            id: id,
            claim: claim,
            source: source,
            passage: passage,
            accessed: accessed,
            usedIn: usedIn,
            sourceFingerprint: fingerprint
        ))
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try registry.encoded().write(to: path, options: .atomic)
        } catch {
            fail("hive-search: can't write \(path.path): \(error)")
        }
        print("saved claim '\(id)' (\(registry.claims.count) total)")

    default:
        fail("usage: hive-search source check|add <registry.json> ...")
    }
}

private func runExample(args initialArgs: [String]) {
    var args = initialArgs
    guard !args.isEmpty else { fail("usage: hive-search example add|find ...") }
    let sub = args.removeFirst()

    switch sub {
    case "add":
        guard !args.isEmpty else { fail("usage: hive-search example add <library.json> --id ... --title ... --category ... --content ... --why ...") }
        let path = expandPath(args.removeFirst())
        guard let id = takeOption("--id", from: &args),
              let title = takeOption("--title", from: &args),
              let category = takeOption("--category", from: &args),
              let content = takeOption("--content", from: &args),
              let why = takeOption("--why", from: &args) else {
            fail("hive-search example add requires --id, --title, --category, --content, and --why")
        }
        let approved = takeOption("--approved", from: &args) ?? isoToday()
        let tags = (takeOption("--tags", from: &args) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let sourcePath = takeOption("--source", from: &args)

        var library = loadExamples(at: path, allowMissing: true)
        library.add(ApprovedExample(
            id: id,
            title: title,
            category: category,
            content: content,
            whyItWorks: why,
            approved: approved,
            tags: tags,
            sourcePath: sourcePath
        ))
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try library.encoded().write(to: path, options: .atomic)
        } catch {
            fail("hive-search: can't write \(path.path): \(error)")
        }
        print("saved example '\(id)' (\(library.examples.count) total)")

    case "find":
        var findArgs = args
        let category = takeOption("--category", from: &findArgs)
        runSearch(presetKinds: [.example], categoryFilter: category, args: findArgs)

    default:
        fail("usage: hive-search example add|find ...")
    }
}

var cliArgs = Array(CommandLine.arguments.dropFirst())
guard !cliArgs.isEmpty else { fail(usage) }
let subcommand = cliArgs.removeFirst()

switch subcommand {
case "query":
    runSearch(presetKinds: nil, args: cliArgs)
case "shelf":
    runSearch(presetKinds: [.shelf], args: cliArgs)
case "recall":
    runSearch(presetKinds: [.recall], args: cliArgs)
case "source":
    runSource(args: cliArgs)
case "example":
    runExample(args: cliArgs)
default:
    fail(usage)
}
