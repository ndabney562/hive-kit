import Foundation
import Testing
@testable import HiveKit

struct JSONStoreTests {
    struct Note: Codable, Equatable, Sendable {
        var title: String
        var made: Date
        var tagCount: Int = 0
    }

    let when = Date(timeIntervalSince1970: 1_790_000_000)

    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("json-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func defaults() -> UserDefaults {
        let name = "json-store-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: file store

    @Test func fileRoundTripsAndMakesItsFolder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<Note>(url: dir.appendingPathComponent("a/b/note.json"))
        #expect(store.load() == nil)
        try store.save(Note(title: "hi", made: when))
        #expect(store.load() == Note(title: "hi", made: when))
        #expect(store.exists)
    }

    @Test func fileMissingOrCorruptGivesTheDefault() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.json")
        let store = JSONFileStore<Note>(url: url)
        let fallback = Note(title: "default", made: when)
        #expect(store.load(default: fallback) == fallback)
        try Data("{not json".utf8).write(to: url)
        #expect(store.load() == nil)
        #expect(store.load(default: fallback) == fallback)
        #expect(store.exists)  // a corrupt file is still there; load never deletes it
    }

    @Test func fileSaveReplacesWholeFileAtomically() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.json")
        let store = JSONFileStore<Note>(url: url)
        try store.save(Note(title: String(repeating: "long ", count: 200), made: when))
        try store.save(Note(title: "short", made: when))
        #expect(store.load()?.title == "short")
        // Only the file itself is left in the folder: no temporary file beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["note.json"])
    }

    @Test func fileRemoveDeletesAndIgnoresMissing() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<Note>(url: dir.appendingPathComponent("note.json"))
        store.remove()  // nothing there: no throw
        try store.save(Note(title: "x", made: when))
        store.remove()
        #expect(!store.exists)
        #expect(store.load() == nil)
    }

    @Test func applicationSupportPathIsUnderTheBaseFolder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<Note>.applicationSupport("HiveTest/note.json", base: dir)
        #expect(store.url == dir.appendingPathComponent("HiveTest/note.json"))
        let real = JSONFileStore<Note>.applicationSupport("HiveTest/note.json")
        #expect(real.url.path.hasSuffix("HiveTest/note.json"))
        #expect(real.url.path.contains("Application Support") || real.url.path.contains(".local/share"))
    }

    @Test func codingOptionsChangeTheBytes() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.json")
        let store = JSONFileStore<Note>(url: url, coding: .init(dates: .iso8601, snakeCaseKeys: true, sortedKeys: true))
        try store.save(Note(title: "t", made: when, tagCount: 2))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == #"{"made":"2026-09-21T14:13:20Z","tag_count":2,"title":"t"}"#)
        #expect(store.load() == Note(title: "t", made: when, tagCount: 2))
        // Plain coding can't read snake-case keys: that's a corrupt file to it, so it gives nil.
        #expect(JSONFileStore<Note>(url: url).load() == nil)
    }

    @Test func plainCodingMatchesAFreshJSONEncoder() throws {
        let note = Note(title: "same", made: when)
        let mine = try JSONCoding.plain.encoder().encode(note)
        // Same JSON as a fresh encoder (key order aside), so files saved before the move still read.
        let a = try JSONSerialization.jsonObject(with: mine) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? NSDictionary
        #expect(a != nil && a == b)
        #expect(try JSONDecoder().decode(Note.self, from: mine) == note)
        #expect(JSONCoding.plain.decode(Note.self, from: mine) == note)
        #expect(JSONCoding.plain.decode(Note.self, from: nil) == nil)
    }

    // MARK: defaults store

    @Test func defaultsRoundTripAndRemove() throws {
        let d = defaults()
        let store = JSONDefaultsStore<Note>(key: "note", defaults: d)
        #expect(store.load() == nil)
        try store.save(Note(title: "kept", made: when))
        #expect(store.load() == Note(title: "kept", made: when))
        #expect(d.data(forKey: "note") != nil)  // stored as JSON bytes under the key
        store.remove()
        #expect(store.load() == nil)
    }

    @Test func defaultsCorruptOrWrongTypeGivesTheDefault() {
        let d = defaults()
        let store = JSONDefaultsStore<Note>(key: "note", defaults: d)
        let fallback = Note(title: "default", made: when)
        d.set(Data("nope".utf8), forKey: "note")
        #expect(store.load(default: fallback) == fallback)
        d.set("a string, not data", forKey: "note")
        #expect(store.load() == nil)
    }

    @Test func defaultsKeysAreSeparate() throws {
        let d = defaults()
        let a = JSONDefaultsStore<[String: Int]>(key: "a", defaults: d)
        let b = JSONDefaultsStore<[String: Int]>(key: "b", defaults: d)
        try a.save(["x": 1])
        #expect(b.load() == nil)
        #expect(a.load() == ["x": 1])
    }
}
