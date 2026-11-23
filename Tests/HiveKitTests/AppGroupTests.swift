import Foundation
import Testing
@testable import HiveKit

struct AppGroupTests {
    let group = "group.com.example.test"
    let box = URL(filePath: "/groups/test")

    @Test func usesTheContainerWhenThereIsOne() {
        let lookup: (String) -> URL? = { [box, group] in $0 == group ? box : nil }
        for fallback in [AppGroup.Fallback.none, .applicationSupport, .temporary] {
            #expect(AppGroup.folder(group, fallback: fallback, container: lookup) == box)
        }
        #expect(AppGroup.url(group, "score/latest.json", container: lookup)?.path == "/groups/test/score/latest.json")
    }

    @Test func eachFallbackKeepsTheFolderAppsUsedBefore() {
        let none: (String) -> URL? = { _ in nil }
        #expect(AppGroup.folder(group, fallback: .none, container: none) == nil)
        #expect(AppGroup.url(group, "widget.json", container: none) == nil)
        #expect(AppGroup.folder(group, fallback: .temporary, container: none) == FileManager.default.temporaryDirectory)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #expect(AppGroup.folder(group, fallback: .applicationSupport, container: none)?.standardizedFileURL
                == support?.standardizedFileURL)
    }

    @Test func jsonFileStoreInAnAppGroup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("app-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(JSONFileStore<[String: Int]>.appGroup(group, "widget.json", coding: .readable,
                                                                      container: { _ in dir }))
        #expect(store.url == dir.appendingPathComponent("widget.json") && store.coding == .readable)
        try store.save(["done": 2])
        #expect(store.load() == ["done": 2])
        #expect(JSONFileStore<[String: Int]>.appGroup(group, "widget.json", container: { _ in nil }) == nil)
    }
}
