import Foundation
import Testing
@testable import HiveKit

/// Hive build order #57 (Pattern 96): cross-app interface & workflow pattern analysis.
/// Fictional fixtures only: hive-kit is public and holds no personal data.
struct HivePatternTests {
    private func makeRepo(_ name: String, in parent: URL, files: [String: String]) throws -> PatternRepo {
        let root = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let fileURL = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return PatternRepo(name: name, root: root)
    }

    private func makeTempRoot() throws -> URL {
        let name = "hive-pattern-test-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func detectsRepeatedInterfaceViewAcrossTwoAppsAndEstimatesCost() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = try makeRepo("AppAlpha", in: root, files: [
            "Sources/StatusBadge.swift": """
            import SwiftUI
            struct StatusBadge: View {
                let text: String
                var body: some View { Text(text) }
            }
            """,
        ])
        let beta = try makeRepo("AppBeta", in: root, files: [
            "UI/StatusBadge.swift": """
            import SwiftUI
            struct StatusBadge: View {
                let label: String
                var body: some View { Text(label) }
            }
            """,
        ])

        let proposals = HivePattern.scan(repos: [alpha, beta], rules: [])
        #expect(proposals.count == 1)
        let p = try #require(proposals.first)
        #expect(p.category == .interface)
        #expect(p.targetPackage == .hiveDesign)
        #expect(p.action == .extractNew)
        #expect(p.repoCount == 2)
        #expect(p.fileCount == 2)
        #expect(p.migrationCost.tier == .low)
        #expect(p.uses.contains { $0.repo == "AppAlpha" && $0.file == "Sources/StatusBadge.swift" && $0.line == 2 })
        #expect(p.uses.contains { $0.repo == "AppBeta" && $0.file == "UI/StatusBadge.swift" && $0.line == 2 })
    }

    @Test func marksAdoptExistingWhenSharedPackageAlreadyDefinesSymbol() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = try makeRepo("AppAlpha", in: root, files: [
            "StatusBadge.swift": "struct StatusBadge: View {\n    var body: some View { EmptyView() }\n}\n",
        ])
        let beta = try makeRepo("AppBeta", in: root, files: [
            "StatusBadge.swift": "struct StatusBadge: View {\n    var body: some View { EmptyView() }\n}\n",
        ])
        let shared = try makeRepo("SharedDesign", in: root, files: [
            "Sources/StatusBadge.swift": "public struct StatusBadge: View {\n    public var body: some View { EmptyView() }\n}\n",
        ])

        let proposals = HivePattern.scan(repos: [alpha, beta], sharedPackages: [shared], rules: [])
        let p = try #require(proposals.first)
        #expect(p.action == .adoptExisting)
        #expect(p.targetPackage == .hiveDesign)
    }

    @Test func detectsRepeatedUserDefaultsJsonStores() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeCode = """
        import Foundation
        final class NotesStore {
            func save(_ items: [String]) throws {
                let data = try JSONEncoder().encode(items)
                UserDefaults.standard.set(data, forKey: "notes")
            }
        }
        """
        let alpha = try makeRepo("AppAlpha", in: root, files: ["NotesStore.swift": storeCode])
        let beta = try makeRepo("AppBeta", in: root, files: ["LocalNotesStore.swift": storeCode])

        let proposals = HivePattern.scan(repos: [alpha, beta])
        let ruleHit = try #require(proposals.first { $0.id == "rule:json-userdefaults-store" })
        #expect(ruleHit.category == .workflow)
        #expect(ruleHit.targetPackage == .hiveKit)
        #expect(ruleHit.action == .adoptExisting)  // HiveKit `JSONDefaultsStore` since 1.29.0
        #expect(ruleHit.repoCount == 2)
    }

    @Test func appGroupRuleAsksToAdoptTheSharedHelper() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let byHand = """
        import Foundation
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.x")?
            .appendingPathComponent("widget.json")
        """
        let adopted = """
        import HiveKit
        let store = JSONFileStore<[String]>.appGroup("group.x", "widget.json")
        """
        let alpha = try makeRepo("AppAlpha", in: root, files: ["Widget.swift": byHand, "Adopted.swift": adopted])
        let hit = try #require(HivePattern.scan(repos: [alpha]).first { $0.id == "rule:app-group-container" })
        #expect(hit.action == .adoptExisting)
        #expect(hit.uses.map(\.file) == ["Widget.swift"])
    }

    @Test func jsonStoreRulesAskToAdoptTheSharedStoreEvenInOneRepo() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileCode = """
        import Foundation
        struct DigestStore {
            func save(_ items: [String]) throws {
                let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                try JSONEncoder().encode(items).write(to: base.appendingPathComponent("d.json"))
            }
        }
        """
        let adopted = """
        import Foundation
        import HiveKit
        let store = JSONFileStore<[String]>.applicationSupport("App/d.json")
        let notes = JSONDefaultsStore<[String]>(key: "notes", defaults: UserDefaults.standard)
        """
        let alpha = try makeRepo("AppAlpha", in: root, files: ["DigestStore.swift": fileCode, "Adopted.swift": adopted])

        let proposals = HivePattern.scan(repos: [alpha])
        let hit = try #require(proposals.first { $0.id == "rule:json-file-store" })
        #expect(hit.action == .adoptExisting)
        #expect(hit.uses.map(\.file) == ["DigestStore.swift"])  // the file already on the shared store is not flagged
        #expect(!proposals.contains { $0.id == "rule:json-userdefaults-store" })
    }

    @Test func detectsRawVerticalScrollViewButIgnoresHorizontalAndHMScroll() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeRepo("AppAlpha", in: root, files: [
            "BadVertical.swift": "struct A { func v() { ScrollView { Text(\"hi\") } } }\n",
            "ExplicitVertical.swift": "struct B { func v() { ScrollView(.vertical) { Text(\"hi\") } } }\n",
            "OkHorizontal.swift": "struct C { func v() { ScrollView(.horizontal) { Text(\"hi\") } } }\n",
            "OkHMScroll.swift": "struct D { func v() { HMScroll { Text(\"hi\") } } }\n",
        ])

        let proposals = HivePattern.scan(repos: [app])
        let hit = try #require(proposals.first { $0.id == "rule:raw-vertical-scrollview" })
        #expect(hit.action == .adoptExisting)
        #expect(hit.targetPackage == .hiveDesign)
        #expect(hit.fileCount == 2)
        #expect(hit.uses.map(\.file).sorted() == ["BadVertical.swift", "ExplicitVertical.swift"])
    }

    @Test func singleRepoTypeDoesNotTriggerExtraction() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeRepo("AppAlpha", in: root, files: [
            "OnlyHere.swift": "struct UniqueThing {\n    let x: Int\n}\n",
        ])

        let proposals = HivePattern.scan(repos: [app], minRepos: 2, rules: [])
        #expect(proposals.isEmpty)
    }

    @Test func isolatedRepoAddsBuildTimePrivacyBoundaryNote() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = try makeRepo("AppAlpha", in: root, files: [
            "Card.swift": "struct MetricCard: View {\n    var body: some View { EmptyView() }\n}\n",
        ])
        let partner = try makeRepo("PartnerApp", in: root, files: [
            "Card.swift": "struct MetricCard: View {\n    var body: some View { EmptyView() }\n}\n",
        ])

        let proposals = HivePattern.scan(
            repos: [alpha, partner],
            isolatedRepos: ["PartnerApp"],
            rules: []
        )
        let p = try #require(proposals.first)
        #expect(p.privacyBoundaryNote?.contains("PartnerApp") == true)
        #expect(p.privacyBoundaryNote?.contains("Build-time sharing only") == true)
    }

    @Test func migrationCostTiersScaleWithFilesAndLines() throws {
        let lowUses = [
            PatternUse(repo: "A", file: "f1.swift", line: 1, symbol: "S", lineCount: 20, excerpt: "S"),
            PatternUse(repo: "B", file: "f2.swift", line: 1, symbol: "S", lineCount: 25, excerpt: "S"),
        ]
        #expect(MigrationCost.estimate(uses: lowUses, action: .extractNew).tier == .low)

        let mediumUses = (1...5).map { i in
            PatternUse(repo: "R\(i)", file: "f\(i).swift", line: 1, symbol: "S", lineCount: 40, excerpt: "S")
        }
        #expect(MigrationCost.estimate(uses: mediumUses, action: .extractNew).tier == .medium)

        let highUses = (1...9).map { i in
            PatternUse(repo: "R\(i)", file: "f\(i).swift", line: 1, symbol: "S", lineCount: 60, excerpt: "S")
        }
        #expect(MigrationCost.estimate(uses: highUses, action: .extractNew).tier == .high)
    }

    @Test func skipsTestsAndBuildDirectories() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = try makeRepo("AppAlpha", in: root, files: [
            ".build/Noise.swift": "struct HelperBox { let v = 1 }\n",
            "build/dd/SourcePackages/Pkg.swift": "struct BuildBox { let v = 1 }\n",
            "AppAlphaTests/HelperTests.swift": "struct HelperBox { let v = 1 }\n",
        ])
        let beta = try makeRepo("AppBeta", in: root, files: [
            "Sources/HelperBox.swift": "struct HelperBox { let v = 1 }\n",
            "Sources/BuildBox.swift": "struct BuildBox { let v = 1 }\n",
        ])

        let proposals = HivePattern.scan(repos: [alpha, beta], rules: [])
        #expect(proposals.isEmpty)
    }

    @Test func ignoresCommentBracesAndBlockCommentDeclarations() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let code = """
        // Example: {
        /*
        struct FakeCommented { let v = 1 }
        */
        struct RealHelper {
            let value = 1
        }
        """
        let alpha = try makeRepo("AppAlpha", in: root, files: ["Helper.swift": code])
        let beta = try makeRepo("AppBeta", in: root, files: ["Helper.swift": code])

        let proposals = HivePattern.scan(repos: [alpha, beta], rules: [])
        #expect(proposals.map(\.id) == ["symbol:RealHelper"])
        #expect(proposals.first?.uses.first?.lineCount == 3)
    }

    @Test func distinguishesPublicOpenPackageVisibilityAndOwningSharedPackage() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = try makeRepo("AppAlpha", in: root, files: [
            "Models.swift": """
            struct PkgHelper { let x = 1 }
            class OpenService { func run() {} }
            struct WrongPkgStore { let x = 1 }
            """,
        ])
        let beta = try makeRepo("AppBeta", in: root, files: [
            "Models.swift": """
            struct PkgHelper { let x = 1 }
            class OpenService { func run() {} }
            struct WrongPkgStore { let x = 1 }
            """,
        ])
        let sharedKit = try makeRepo("hive-kit", in: root, files: [
            "Shared.swift": """
            package struct PkgHelper { let x = 1 }
            open class OpenService { public init() {} }
            """,
        ])
        let sharedDesign = try makeRepo("hive-design", in: root, files: [
            "Design.swift": """
            public struct WrongPkgStore { public init() {} }
            """,
        ])

        let proposals = HivePattern.scan(repos: [alpha, beta], sharedPackages: [sharedKit, sharedDesign], rules: [])
        let byID = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0) })

        #expect(byID["symbol:PkgHelper"]?.action == .extractNew)
        #expect(byID["symbol:OpenService"]?.action == .adoptExisting)
        #expect(byID["symbol:OpenService"]?.targetPackage == .hiveKit)
        // A workflow symbol only declared in hive-design must not claim to exist in hive-kit
        #expect(byID["symbol:WrongPkgStore"]?.action == .extractNew)
        #expect(byID["symbol:WrongPkgStore"]?.targetPackage == .hiveKit)
    }

    @Test func preservesMultilineStringStateAcrossLinesAndIgnoresDeclarationsInsideStrings() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let snippet = """
        let marker = \"\"\"
        /*
        struct FakeInsideString { let x = 1 }
        \"\"\"
        let rawMarker = #\"\"\"
        \"\"\"
        /*
        struct FakeInsideRaw { let y = 2 }
        \"\"\"#
        let singleRaw = #"/* \\"#
        struct RealAfterMultiline { let value = 1 }
        """

        let alpha = try makeRepo("AppAlpha", in: root, files: ["Sample.swift": snippet])
        let beta = try makeRepo("AppBeta", in: root, files: ["Sample.swift": snippet])

        let proposals = HivePattern.scan(repos: [alpha, beta], rules: [])

        #expect(proposals.map(\.id) == ["symbol:RealAfterMultiline"])
    }

    @Test func noPersonalDataInPatternCodeAndFixtures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Sources/HiveKit/HivePattern.swift",
            "Sources/hive-pattern/main.swift",
            "Tests/HiveKitTests/HivePatternTests.swift",
        ]
        let forbiddenWords = [
            "nd" + "abney", "No" + "ah", "Di" + "nk",
            "Et" + "sy", "Tik" + "Tok", "gh" + "u_", "gh" + "p_",
        ]
        for rel in files {
            let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            for forbidden in forbiddenWords {
                #expect(!text.contains(forbidden), "\(rel) contains \(forbidden)")
            }
        }
    }
}
