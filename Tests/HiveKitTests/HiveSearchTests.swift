import Foundation
import Testing
@testable import HiveKit

/// Hive build order #50–#54 (Shelf 4, Recall 22, Source 21, Example 95, Search 61).
/// Fictional fixtures only: hive-kit is public and holds no personal data.
struct HiveSearchTests {
    private func makeTempDir() throws -> URL {
        let name = "hive-search-test-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let children = try? FileManager.default.contentsOfDirectory(
            at: dir.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        return children?.first { $0.lastPathComponent == name } ?? dir
    }

    @Test func sha256MatchesKnownVector() {
        #expect(HiveSearchHash.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(HiveSearchHash.fingerprint("Hello\r\nWorld  ") == HiveSearchHash.fingerprint("Hello\nWorld"))
    }

    @Test func shelfFindsDeliverableWithPreviewStatusCaptionAndUsage() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let schedule = root.appendingPathComponent("schedule")
        let piece = root.appendingPathComponent("pieces/widget-video")
        let renders = piece.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: schedule, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)

        try "{\"episodes\":[{\"slug\":\"widget-video\",\"status\":\"shipped\"}]}"
            .write(to: schedule.appendingPathComponent("queue.json"), atomically: true, encoding: .utf8)
        try "[{\"slug\":\"widget-video\",\"at\":\"2026-11-18T16:00\"}]"
            .write(to: schedule.appendingPathComponent("posts.json"), atomically: true, encoding: .utf8)
        try "{\"widget-video\":\"How widgets work in 60 seconds\"}"
            .write(to: schedule.appendingPathComponent("captions.json"), atomically: true, encoding: .utf8)

        try "{\"title\":\"How Widgets Work\"}"
            .write(to: piece.appendingPathComponent("piece.json"), atomically: true, encoding: .utf8)
        try "Title: How Widgets Work\nDescription: Short explainer\n"
            .write(to: piece.appendingPathComponent("upload.md"), atomically: true, encoding: .utf8)
        try Data("mp4".utf8).write(to: renders.appendingPathComponent("final.mp4"))

        var index = HiveSearchIndex()
        index.add(HiveWorkspaceScanner.scan(roots: [root]))
        let hits = index.search(SearchQuery(text: "widgets", kinds: [.shelf]))

        #expect(hits.count == 1)
        let item = try #require(hits.first?.item)
        #expect(item.title == "How Widgets Work")
        #expect(item.metadata["status"] == "shipped")
        #expect(item.metadata["usageCount"] == "1")
        #expect(item.target == .file(renders.appendingPathComponent("final.mp4").path))
        #expect(item.body.contains("How widgets work in 60 seconds"))
        #expect(item.relatedTargets.contains(.file(piece.appendingPathComponent("upload.md").path)))
    }

    @Test func recallReturnsSupportingPassageDateAndRanksCurrentAboveArchived() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        try """
        # Handoff: sample-app

        ## Done
        - **2026-11-18:** Chose JSON storage over SQLite because zero dependencies keeps Linux CI fast.
        """.write(to: root.appendingPathComponent("HANDOFF.md"), atomically: true, encoding: .utf8)

        try """
        # Archive

        ## Done
        - **2026-11-02:** Earlier trial used JSON storage while comparing SQLite options.
        """.write(to: docs.appendingPathComponent("HANDOFF-ARCHIVE.md"), atomically: true, encoding: .utf8)

        var index = HiveSearchIndex()
        index.add(HiveWorkspaceScanner.scan(roots: [root]))

        let allHits = index.search(SearchQuery(text: "JSON storage SQLite", kinds: [.recall]))
        #expect(allHits.count == 2)
        #expect(allHits[0].item.freshness == .current)
        #expect(allHits[0].item.date == "2026-11-18")
        #expect(allHits[0].item.target.line == 3)
        #expect(allHits[0].snippet.contains("zero dependencies"))
        #expect(allHits[1].item.freshness == .archived)

        let currentOnly = index.search(SearchQuery(text: "JSON storage", kinds: [.recall], includeArchived: false))
        #expect(currentOnly.count == 1)
        #expect(currentOnly[0].item.freshness == .current)
    }

    @Test func sourceRegistryDetectsChangedAndMissingSources() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let docA = root.appendingPathComponent("source-a.txt")
        let docB = root.appendingPathComponent("source-b.txt")
        let initialA = "Widgets increased studio efficiency by 42 percent in 2025."
        let initialB = "Original measurement baseline was 10 units."
        try initialA.write(to: docA, atomically: true, encoding: .utf8)
        try initialB.write(to: docB, atomically: true, encoding: .utf8)

        var registry = SourceRegistry()
        registry.upsert(SourceClaim(
            id: "c1",
            claim: "Widgets improved efficiency 42%",
            source: docA.path,
            passage: "efficiency by 42 percent",
            accessed: "2026-11-18",
            usedIn: ["scripts/ep1.md:12"],
            sourceFingerprint: HiveSearchHash.fingerprint(initialA)
        ))
        registry.upsert(SourceClaim(
            id: "c2",
            claim: "Baseline was 10 units",
            source: docB.path,
            passage: "10 units",
            accessed: "2026-11-18",
            usedIn: ["scripts/ep2.md:8"],
            sourceFingerprint: HiveSearchHash.fingerprint(initialB)
        ))
        registry.upsert(SourceClaim(
            id: "c3",
            claim: "Missing archive entry",
            source: root.appendingPathComponent("gone.txt").path,
            passage: "archived text",
            accessed: "2026-11-10"
        ))

        let reader: (String) -> String? = { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        }

        // Before edit: c1 and c2 are clean, only c3 is unreadable.
        let initialDrifts = registry.checkDrift(using: reader)
        #expect(initialDrifts.map(\.claimID) == ["c3"])

        // Edit docA while preserving passage, edit docB removing passage.
        try "Header note.\nWidgets increased studio efficiency by 42 percent in 2025."
            .write(to: docA, atomically: true, encoding: .utf8)
        try "Revised measurement baseline was 25 units."
            .write(to: docB, atomically: true, encoding: .utf8)

        let afterDrifts = registry.checkDrift(using: reader)
        #expect(afterDrifts.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: afterDrifts.map { ($0.claimID, $0.reason) })
        #expect(byID["c1"] == "source changed (supporting passage still present)")
        #expect(byID["c2"] == "source changed and supporting passage not found")
        #expect(byID["c3"] == "source unreadable")

        let decoded = try SourceRegistry.decode(registry.encoded())
        #expect(decoded == registry)

        var index = HiveSearchIndex()
        index.add(sources: registry, driftedIDs: Set(afterDrifts.map(\.claimID)))
        let sourceHits = index.search(SearchQuery(text: "efficiency", kinds: [.source]))
        #expect(sourceHits.first?.item.freshness == .staleSource)
        #expect(sourceHits.first?.item.relatedTargets == [.file("scripts/ep1.md", line: 12)])
    }

    @Test func exampleLibraryAndVoiceProfileBridge() throws {
        var lib = ExampleLibrary()
        lib.add(ApprovedExample(
            id: "hook-1",
            title: "Concrete visual hook",
            category: "video-hook",
            content: "Lead with the broken prototype on the workbench before naming the concept.",
            whyItWorks: "Creates immediate curiosity without a title card.",
            approved: "2026-11-15",
            tags: ["hook", "pacing"],
            sourcePath: "guides/hooks.md:4"
        ))
        // Replacing same id updates without duplicating
        lib.add(ApprovedExample(
            id: "hook-1",
            title: "Concrete visual hook",
            category: "video-hook",
            content: "Lead with the broken prototype on the workbench in frame zero.",
            whyItWorks: "Immediate motion prevents early drop-off.",
            approved: "2026-11-18",
            tags: ["hook", "pacing"],
            sourcePath: "guides/hooks.md:4"
        ))
        #expect(lib.examples.count == 1)

        let roundTrip = try ExampleLibrary.decode(lib.encoded())
        #expect(roundTrip == lib)

        let voice = VoiceProfile(
            name: "Studio Notes",
            usedFor: "Release summaries",
            tone: ["direct"],
            rules: ["Lead with the change."],
            examples: [.init(text: "Ships faster startup in 2 seconds.", note: "Concrete result first.", approved: "2026-11-16")]
        )

        var index = HiveSearchIndex()
        index.add(examples: lib)
        index.add(voiceProfile: voice)

        let hookHits = index.search(SearchQuery(text: "workbench", kinds: [.example]))
        #expect(hookHits.count == 1)
        #expect(hookHits[0].item.target == .file("guides/hooks.md", line: 4))

        let voiceHits = index.search(SearchQuery(text: "startup", kinds: [.example]))
        #expect(voiceHits.count == 1)
        #expect(voiceHits[0].item.metadata["profile"] == "Studio Notes")
    }

    @Test func unifiedSearchIndexesFeedsWithHiveLinksAndEnforcesScopes() throws {
        let now = ISO8601DateFormatter().date(from: "2099-01-15T12:00:00Z")!
        let utc = TimeZone(identifier: "UTC")!

        let tempoData = try #require(try HiveFixture.file("hive-tempo", .normal, now: now, timeZone: utc))
        let worldData = try #require(try HiveFixture.file("hiveworld", .normal, now: now, timeZone: utc))
        let scoreData = try #require(try HiveFixture.file("health-score", .normal, now: now, timeZone: utc))
        let tempo = try #require(try HiveFeed.decode(tempoData, as: TempoSummary.self)).summary
        let world = try #require(try HiveFeed.decode(worldData, as: WorldSummary.self)).summary
        let score = try #require(try HiveFeed.decode(scoreData, as: ScoreSummary.self)).summary

        var index = HiveSearchIndex()
        index.addFeed(tempo: tempo, world: world, score: score, scope: "personal")
        index.add([
            SearchItem(
                id: "partner:note",
                kind: .recall,
                scope: "partner",
                title: "Shared checklist guide",
                body: "Review checklist items before signing off.",
                target: .file("shared/checklist.md")
            ),
        ])

        let taskHits = index.search(SearchQuery(text: tempo.current?.title ?? "Sample", scopes: ["personal"]))
        #expect(!taskHits.isEmpty)
        let firstTask = try #require(taskHits.first(where: { $0.item.kind == .task })?.item)
        #expect(firstTask.target.kind == .hiveLink)
        #expect(firstTask.target.hiveLink != nil)

        // Strict data boundary: querying `partner` scope must never return `personal` items.
        let partnerHits = index.search(SearchQuery(text: "", scopes: ["partner"]))
        #expect(partnerHits.map(\.item.id) == ["partner:note"])
    }

    @Test func scannerSkipsNoiseDirsAndExtractsScriptSources() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let noise = root.appendingPathComponent(".build")
        let piece = root.appendingPathComponent("pieces/compass")
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: piece, withIntermediateDirectories: true)

        // Should be ignored inside .build
        try "# Noise\n\nSecret build artifact note".write(to: noise.appendingPathComponent("HANDOFF.md"), atomically: true, encoding: .utf8)

        try """
        # Project: Sample Studio

        - **Test command:** `swift test`

        ## Milestones
        - [x] Setup complete
        - [ ] Export check
        """.write(to: root.appendingPathComponent("PROJECT.md"), atomically: true, encoding: .utf8)

        try """
        # The Compass

        ## Sources
        - Maritime Museum Archive: https://example.org/compass

        Caption: Short caption text.
        """.write(to: piece.appendingPathComponent("script-v2.md"), atomically: true, encoding: .utf8)

        var index = HiveSearchIndex()
        index.add(HiveWorkspaceScanner.scan(roots: [root]))

        #expect(index.search(SearchQuery(text: "artifact")).isEmpty)

        let projectHits = index.search(SearchQuery(text: "Sample Studio", kinds: [.project]))
        #expect(projectHits.count == 1)
        #expect(projectHits[0].item.subtitle == "\(root.lastPathComponent) · 1/2 milestones")

        let sourceHits = index.search(SearchQuery(text: "Maritime Museum", kinds: [.source]))
        #expect(sourceHits.count == 1)
        #expect(sourceHits[0].item.target == .web("https://example.org/compass"))
        #expect(sourceHits[0].item.relatedTargets == [.file(piece.appendingPathComponent("script-v2.md").path, line: 4)])
    }

    @Test func datedBundlesInSameDirectoryStayDistinct() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("v1".utf8).write(to: root.appendingPathComponent("2026-11-18-widget.mp4"))
        try "First caption".write(to: root.appendingPathComponent("2026-11-18-widget.txt"), atomically: true, encoding: .utf8)
        try Data("v2".utf8).write(to: root.appendingPathComponent("2026-11-19-widget.mp4"))
        try "Second caption".write(to: root.appendingPathComponent("2026-11-19-widget.txt"), atomically: true, encoding: .utf8)

        var index = HiveSearchIndex()
        index.add(HiveWorkspaceScanner.scan(roots: [root]))
        let hits = index.search(SearchQuery(text: "widget", kinds: [.shelf]))
        #expect(hits.count == 2)
        #expect(Set(hits.compactMap(\.item.date)) == ["2026-11-18", "2026-11-19"])
        #expect(Set(hits.map(\.item.id)).count == 2)
    }

    @Test func categoryFilterRunsBeforeLimitAndReferenceStripsLine() {
        var lib = ExampleLibrary()
        for i in 1...120 {
            lib.add(ApprovedExample(
                id: "other-\(i)",
                title: "Pacing pattern \(i)",
                category: "pacing",
                content: "Pacing pattern cut example \(i)",
                whyItWorks: "Keeps attention",
                approved: "2026-11-18"
            ))
        }
        lib.add(ApprovedExample(
            id: "hook-target",
            title: "Target hook",
            category: "video-hook",
            content: "Hook pattern example",
            whyItWorks: "Starts with action",
            approved: "2026-11-18"
        ))

        var index = HiveSearchIndex()
        index.add(examples: lib)
        let hits = index.search(SearchQuery(text: "pattern", kinds: [.example], category: "video-hook", limit: 5))
        #expect(hits.count == 1)
        #expect(hits.first?.item.id == "example:hook-target")
        #expect(SearchTarget.parseReference("docs/report.md:12") == .file("docs/report.md", line: 12))
    }

    @Test func noPersonalDataInSearchFixtures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let searchFiles = [
            "Sources/HiveKit/Search/SearchRecord.swift",
            "Sources/HiveKit/Search/SearchIndex.swift",
            "Sources/HiveKit/Search/WorkspaceScanner.swift",
            "Sources/hive-search/main.swift",
            "Tests/HiveKitTests/HiveSearchTests.swift",
        ]
        let forbiddenWords = [
            "nd" + "abney", "No" + "ah", "Di" + "nk",
            "Et" + "sy", "Tik" + "Tok", "gh" + "u_", "gh" + "p_",
        ]
        for rel in searchFiles {
            let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            for forbidden in forbiddenWords {
                #expect(!text.contains(forbidden), "\(rel) contains \(forbidden)")
            }
        }
    }
}
