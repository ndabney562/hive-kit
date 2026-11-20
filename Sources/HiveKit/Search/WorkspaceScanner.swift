import Foundation

/// Read-only filesystem scanner that indexes existing Hive workspace projects, docs, deliverables, and feeds
/// without creating or duplicating storage.
public enum HiveWorkspaceScanner {
    static let skippedDirectories: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", ".venv", ".venv-tts", ".venv-agent",
        "__pycache__", ".wrangler", "frames", "models", "hf-cache", ".Trash", "release-evidence",
    ]

    private static let maxTextBytes = 512 * 1024

    private static let recallFileNames: Set<String> = [
        "handoff.md", "handoff-archive.md", "ideas.md", "lessons-shared.md",
        "team-memory.md", "agents.md", "style.md", "decisions.md", "global-todo.md",
    ]

    /// Scans directory trees or explicit files into `SearchItem` records.
    public static func scan(roots: [URL], scope: String = "personal") -> [SearchItem] {
        let fm = FileManager.default
        var items: [SearchItem] = []
        var visitedDirs: Set<String> = []
        var scannedFiles: Set<String> = []

        func walk(_ url: URL) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

            if !isDir.boolValue {
                let realFile = url.resolvingSymlinksInPath().path
                guard scannedFiles.insert(realFile).inserted else { return }
                items.append(contentsOf: scanFile(url, scope: scope))
                return
            }

            if skippedDirectories.contains(url.lastPathComponent) { return }
            let canonicalDir = url.resolvingSymlinksInPath().path
            guard visitedDirs.insert(canonicalDir).inserted else { return }

            if url.lastPathComponent == "pieces" {
                items.append(contentsOf: scanPiecesDirectory(url, scope: scope))
            }

            items.append(contentsOf: scanBundleDirectory(url, scope: scope))

            guard let children = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            let sorted = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in sorted {
                walk(child)
            }
        }

        for root in roots {
            walk(root)
        }
        return items
    }

    /// Reads `<app>.json` feed snapshots from a local directory using `HiveFeed.decode`.
    public static func scanFeeds(directory: URL, scope: String = "personal") -> [SearchItem] {
        let fm = FileManager.default
        func load<S: Decodable & Sendable>(_ name: String, as type: S.Type) -> S? {
            let file = directory.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: file),
                  let env = try? HiveFeed.decode(data, as: type) else { return nil }
            return env.summary
        }

        guard fm.fileExists(atPath: directory.path) else { return [] }
        var index = HiveSearchIndex()
        index.addFeed(
            tempo: load("hive-tempo", as: TempoSummary.self),
            world: load("hiveworld", as: WorldSummary.self),
            score: load("health-score", as: ScoreSummary.self),
            business: load("ai-business-db", as: BusinessSummary.self),
            jobs: load("jobs", as: JobsSummary.self),
            releases: load("releases", as: ReleasesSummary.self),
            scope: scope
        )
        return index.items
    }

    // MARK: - Individual file scanning (projects, recall docs, script citations)

    private static func scanFile(_ url: URL, scope: String) -> [SearchItem] {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        guard lower.hasSuffix(".md") else { return [] }

        if lower == "project.md" {
            return scanProjectMarkdown(url, scope: scope).map { [$0] } ?? []
        }
        if isCitationMarkdown(url) {
            return scanScriptSources(url, scope: scope)
        }
        if isRecallFile(url) {
            return scanRecallMarkdown(url, scope: scope)
        }
        return []
    }

    private static func isCitationMarkdown(_ url: URL) -> Bool {
        let lower = url.lastPathComponent.lowercased()
        return lower == "script-v2.md" || lower == "upload.md"
    }

    private static func isRecallFile(_ url: URL) -> Bool {
        let lower = url.lastPathComponent.lowercased()
        if recallFileNames.contains(lower) { return true }
        if lower.hasSuffix("-archive.md") { return true }
        let comps = url.pathComponents.map { $0.lowercased() }
        return comps.contains("docs") && lower.hasSuffix(".md")
    }

    private static func isArchivedPath(_ url: URL) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.contains("archive") { return true }
        let comps = url.pathComponents.map { $0.lowercased() }
        return comps.contains("archive") || comps.contains("_backups")
    }

    private static func readLimitedUTF8(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue <= maxTextBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func scanProjectMarkdown(_ url: URL, scope: String) -> SearchItem? {
        guard let text = readLimitedUTF8(url) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        let titleLine = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }
        let title = titleLine?
            .trimmingCharacters(in: .whitespaces)
            .dropFirst(2)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "Project: ", with: "")
            ?? url.deletingLastPathComponent().lastPathComponent

        let doneCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [x]") }.count
        let openCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") }.count
        let folder = url.deletingLastPathComponent().lastPathComponent
        let subtitle = (doneCount + openCount > 0)
            ? "\(folder) · \(doneCount)/\(doneCount + openCount) milestones"
            : folder

        return SearchItem(
            id: "project:\(url.path)",
            kind: .project,
            scope: scope,
            title: title,
            subtitle: subtitle,
            body: text,
            date: firstISODate(in: text),
            freshness: .current,
            tags: ["project", folder],
            target: .file(url.path, line: 1),
            metadata: ["repo": folder]
        )
    }

    private static func scanRecallMarkdown(_ url: URL, scope: String) -> [SearchItem] {
        guard let text = readLimitedUTF8(url) else { return [] }
        let archived = isArchivedPath(url)
        let freshness: SearchFreshness = archived ? .archived : .current
        let fileLabel = url.lastPathComponent
        let parentLabel = url.deletingLastPathComponent().lastPathComponent
        let rawLines = text.components(separatedBy: .newlines)

        struct Section {
            var heading: String
            var line: Int
            var bodyLines: [String]
        }

        var sections: [Section] = []
        var current = Section(heading: fileLabel, line: 1, bodyLines: [])

        for (idx, raw) in rawLines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
                if !current.bodyLines.isEmpty { sections.append(current) }
                let heading = trimmed.drop(while: { $0 == "#" || $0 == " " })
                current = Section(heading: String(heading), line: idx + 1, bodyLines: [])
            } else {
                current.bodyLines.append(raw)
            }
        }
        if !current.bodyLines.isEmpty { sections.append(current) }

        var results: [SearchItem] = []
        for sec in sections {
            let cleanBody = sec.bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanBody.isEmpty else { continue }

            // Break long bullet logs (e.g. HANDOFF Done lists or build-order logs) into per-entry passages
            // so recall points to the exact entry line and date.
            if sec.bodyLines.count > 25 {
                let bulletChunks = splitTopLevelBullets(sec.bodyLines, startLine: sec.line + (sec.line == 1 ? 0 : 1))
                if bulletChunks.count > 1 {
                    for chunk in bulletChunks {
                        let chunkBody = chunk.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !chunkBody.isEmpty else { continue }
                        let title = firstHeadingOrClause(in: chunkBody) ?? sec.heading
                        results.append(SearchItem(
                            id: "recall:\(url.path):\(chunk.line)",
                            kind: .recall,
                            scope: scope,
                            title: title,
                            subtitle: "\(parentLabel)/\(fileLabel):\(chunk.line) · \(sec.heading)",
                            body: chunkBody,
                            date: firstISODate(in: chunkBody) ?? firstISODate(in: sec.heading),
                            freshness: freshness,
                            tags: ["recall", fileLabel, parentLabel],
                            target: .file(url.path, line: chunk.line),
                            metadata: ["file": fileLabel, "section": sec.heading]
                        ))
                    }
                    continue
                }
            }

            results.append(SearchItem(
                id: "recall:\(url.path):\(sec.line)",
                kind: .recall,
                scope: scope,
                title: sec.heading,
                subtitle: "\(parentLabel)/\(fileLabel):\(sec.line)",
                body: cleanBody,
                date: firstISODate(in: cleanBody) ?? firstISODate(in: sec.heading),
                freshness: freshness,
                tags: ["recall", fileLabel, parentLabel],
                target: .file(url.path, line: sec.line),
                metadata: ["file": fileLabel, "section": sec.heading]
            ))
        }
        return results
    }

    private static func splitTopLevelBullets(_ lines: [String], startLine: Int) -> [(line: Int, lines: [String])] {
        var chunks: [(line: Int, lines: [String])] = []
        var currentLine = startLine
        var buffer: [String] = []

        for (offset, line) in lines.enumerated() {
            let startsTopBullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            if startsTopBullet {
                if !buffer.isEmpty {
                    chunks.append((currentLine, buffer))
                }
                currentLine = startLine + offset
                buffer = [line]
            } else {
                buffer.append(line)
            }
        }
        if !buffer.isEmpty {
            chunks.append((currentLine, buffer))
        }
        return chunks
    }

    private static func firstHeadingOrClause(in text: String) -> String? {
        let first = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty else { return nil }
        let stripped = first.hasPrefix("- ") || first.hasPrefix("* ") ? String(first.dropFirst(2)) : first
        let clean = stripped.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        if clean.count <= 96 { return clean }
        let idx = clean.index(clean.startIndex, offsetBy: 96)
        return String(clean[..<idx]) + "..."
    }

    private static func scanScriptSources(_ url: URL, scope: String) -> [SearchItem] {
        guard let text = readLimitedUTF8(url) else { return [] }
        let slug = url.deletingLastPathComponent().lastPathComponent
        let lines = text.components(separatedBy: .newlines)
        var inSources = false
        var out: [SearchItem] = []

        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^(##\s+)?Sources\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                inSources = true
                continue
            }
            if inSources, !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("*"), !raw.hasPrefix("  ") {
                inSources = false
            }
            guard inSources, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
            let entry = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }

            let webURL = firstWebURL(in: entry)
            let target: SearchTarget = webURL.map(SearchTarget.web) ?? .file(url.path, line: idx + 1)
            out.append(SearchItem(
                id: "source:\(url.path):\(idx + 1)",
                kind: .source,
                scope: scope,
                title: "\(slug): \(shortSourceTitle(entry))",
                subtitle: "\(url.lastPathComponent):\(idx + 1)",
                body: entry,
                date: firstISODate(in: entry),
                freshness: .current,
                tags: ["source", slug],
                target: target,
                relatedTargets: [.file(url.path, line: idx + 1)],
                metadata: ["piece": slug]
            ))
        }
        return out
    }

    // MARK: - Shelf deliverable scanning

    private static func scanPiecesDirectory(_ piecesDir: URL, scope: String) -> [SearchItem] {
        let fm = FileManager.default
        let projectDir = piecesDir.deletingLastPathComponent()
        let projectName = projectDir.lastPathComponent
        let scheduleDir = projectDir.appendingPathComponent("schedule")

        let statuses = loadQueueStatuses(scheduleDir.appendingPathComponent("queue.json"))
        let captions = loadStringDictionary(scheduleDir.appendingPathComponent("captions.json"))
        let usage = loadUsageHistory(scheduleDir: scheduleDir)

        guard let children = try? fm.contentsOfDirectory(at: piecesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var items: [SearchItem] = []
        for pieceDir in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: pieceDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let slug = pieceDir.lastPathComponent
            let pieceJSON = loadJSONObject(pieceDir.appendingPathComponent("piece.json"))
            let uploadURL = pieceDir.appendingPathComponent("upload.md")
            let scriptURL = pieceDir.appendingPathComponent("script-v2.md")
            let briefURL = pieceDir.appendingPathComponent("brief.md")

            let hasMetadata = pieceJSON != nil || fm.fileExists(atPath: uploadURL.path) || fm.fileExists(atPath: scriptURL.path)
            guard hasMetadata else { continue }

            let uploadText = readLimitedUTF8(uploadURL)
            let scriptText = readLimitedUTF8(scriptURL)

            let title = (pieceJSON?["title"] as? String)
                ?? firstHeading(in: scriptText)
                ?? firstHeading(in: uploadText)
                ?? slug

            let previewPath = findPreviewFile(in: pieceDir)
            let status = statuses[slug]
                ?? uploadStatus(in: uploadText)
                ?? (previewPath != nil ? "built" : "draft")

            let captionPath: String?
            let captionText: String?
            if let mapped = captions[slug] {
                captionText = mapped
                captionPath = scheduleDir.appendingPathComponent("captions.json").path
            } else if let scriptCap = extractScriptCaption(from: scriptText) {
                captionText = scriptCap
                captionPath = scriptURL.path
            } else if let uploadText {
                captionText = uploadText
                captionPath = uploadURL.path
            } else {
                captionText = nil
                captionPath = nil
            }

            var related: [String] = []
            for candidate in [uploadURL, scriptURL, briefURL, pieceDir.appendingPathComponent("piece.json")] {
                if fm.fileExists(atPath: candidate.path) { related.append(candidate.path) }
            }

            let deliverable = ShelfDeliverable(
                slug: slug,
                title: title,
                project: projectName,
                status: status,
                previewPath: previewPath,
                captionText: captionText,
                captionPath: captionPath,
                usageHistory: usage[slug] ?? [],
                date: firstISODate(in: (usage[slug] ?? []).joined(separator: " ") + " " + (uploadText ?? "")),
                directoryPath: pieceDir.path,
                relatedPaths: related
            )
            items.append(deliverable.searchItem(scope: scope))
        }
        return items
    }

    private static func scanBundleDirectory(_ dir: URL, scope: String) -> [SearchItem] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }

        // Matches dated deliverable bundles like `2026-11-18-widget.mp4`, `.txt`, `.png`
        let pattern = #"^(\d{4}-\d{2}-\d{2})-(.+)\.(mp4|mov|txt|png|jpg)$"#
        var grouped: [String: (date: String, slug: String, mp4: String?, txt: String?, img: String?)] = [:]

        for child in children {
            let name = child.lastPathComponent
            guard let match = firstMatch(pattern, in: name), match.count == 4 else { continue }
            let date = match[1], slug = match[2], ext = match[3].lowercased()
            let key = "\(date)-\(slug)"
            var entry = grouped[key] ?? (date: date, slug: slug, mp4: nil, txt: nil, img: nil)
            if ext == "mp4" || ext == "mov" { entry.mp4 = child.path }
            else if ext == "txt" { entry.txt = child.path }
            else { entry.img = child.path }
            grouped[key] = entry
        }

        let parent = dir.lastPathComponent
        return grouped.keys.sorted().compactMap { key -> SearchItem? in
            guard let g = grouped[key], g.mp4 != nil || g.img != nil else { return nil }
            let caption = g.txt.flatMap { readLimitedUTF8(URL(fileURLWithPath: $0)) }
            let related = [g.mp4, g.txt, g.img].compactMap { $0 }
            return ShelfDeliverable(
                slug: g.slug,
                title: "\(g.slug) (\(g.date))",
                project: parent,
                status: "ready",
                previewPath: g.mp4 ?? g.img,
                captionText: caption,
                captionPath: g.txt,
                usageHistory: ["bundle \(g.date)"],
                date: g.date,
                directoryPath: dir.path,
                relatedPaths: related
            ).searchItem(scope: scope)
        }
    }

    // MARK: - Metadata helpers

    private static func loadJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func loadStringDictionary(_ url: URL) -> [String: String] {
        guard let obj = loadJSONObject(url) else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    private static func loadQueueStatuses(_ url: URL) -> [String: String] {
        guard let obj = loadJSONObject(url),
              let episodes = obj["episodes"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for ep in episodes {
            if let slug = ep["slug"] as? String, let status = ep["status"] as? String {
                out[slug] = status
            }
        }
        return out
    }

    private static func loadUsageHistory(scheduleDir: URL) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for fileName in ["posts.json", "shorts-posted.json", "reels-posted.json"] {
            let url = scheduleDir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            for row in arr {
                guard let slug = row["slug"] as? String, !slug.isEmpty else { continue }
                let when = (row["at"] as? String) ?? (row["date"] as? String) ?? "recorded"
                let note = "\(when) (\(fileName))"
                if !(out[slug] ?? []).contains(note) {
                    out[slug, default: []].append(note)
                }
            }
        }
        return out
    }

    private static func findPreviewFile(in pieceDir: URL) -> String? {
        let fm = FileManager.default
        let renders = pieceDir.appendingPathComponent("renders")
        for candidate in ["final-captioned.mp4", "final.mp4"] {
            let p = renders.appendingPathComponent(candidate)
            if fm.fileExists(atPath: p.path) { return p.path }
        }
        if let files = try? fm.contentsOfDirectory(at: renders, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            if let anyVideo = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: { $0.pathExtension.lowercased() == "mp4" }) {
                return anyVideo.path
            }
        }
        for name in ["cover.png", "cover.jpg", "thumb.png", "storyboard.png"] {
            let p = pieceDir.appendingPathComponent(name)
            if fm.fileExists(atPath: p.path) { return p.path }
        }
        return nil
    }

    private static func firstHeading(in text: String?) -> String? {
        guard let text else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func uploadStatus(in text: String?) -> String? {
        guard let text else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("status") {
                if trimmed.lowercased().contains("not published") { return "not published" }
                return trimmed
            }
        }
        return nil
    }

    private static func extractScriptCaption(from text: String?) -> String? {
        guard let text else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("caption:") {
                return String(trimmed.dropFirst("caption:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func firstISODate(in text: String) -> String? {
        firstMatch(#"\b(20\d\d-\d{2}-\d{2})\b"#, in: text)?[1]
    }

    private static func firstWebURL(in text: String) -> String? {
        firstMatch(#"(https?://[^\s)>]+)"#, in: text)?[1]
    }

    private static func shortSourceTitle(_ entry: String) -> String {
        let cleaned = entry.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " :-\t"))
        if !cleaned.isEmpty {
            return cleaned.count > 72 ? String(cleaned.prefix(72)) + "..." : cleaned
        }
        return firstWebURL(in: entry) ?? "source"
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { idx in
            let r = match.range(at: idx)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}
