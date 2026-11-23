import Foundation

/// How a store turns values into JSON bytes and back. `plain` is a fresh `JSONEncoder()`/`JSONDecoder()`, so files an
/// app saved before it moved to `JSONFileStore` still read. Value type, so a store stays `Sendable`.
public struct JSONCoding: Sendable, Equatable {
    public enum Dates: Sendable, Equatable {
        /// Foundation's default (seconds since 2001 as a number).
        case deferred
        case iso8601
    }

    public var dates: Dates
    public var snakeCaseKeys: Bool
    public var sortedKeys: Bool

    public init(dates: Dates = .deferred, snakeCaseKeys: Bool = false, sortedKeys: Bool = false) {
        self.dates = dates
        self.snakeCaseKeys = snakeCaseKeys
        self.sortedKeys = sortedKeys
    }

    /// A fresh `JSONEncoder()` / `JSONDecoder()`.
    public static let plain = JSONCoding()
    /// ISO 8601 dates and sorted keys: readable files with stable diffs.
    public static let readable = JSONCoding(dates: .iso8601, sortedKeys: true)

    public func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        if dates == .iso8601 { e.dateEncodingStrategy = .iso8601 }
        if snakeCaseKeys { e.keyEncodingStrategy = .convertToSnakeCase }
        if sortedKeys { e.outputFormatting = [.sortedKeys] }
        return e
    }

    public func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        if dates == .iso8601 { d.dateDecodingStrategy = .iso8601 }
        if snakeCaseKeys { d.keyDecodingStrategy = .convertFromSnakeCase }
        return d
    }

    /// The decoded value, or nil when there are no bytes or they don't decode (a corrupt or older file).
    public func decode<Value: Decodable>(_ type: Value.Type, from data: Data?) -> Value? {
        guard let data else { return nil }
        return try? decoder().decode(type, from: data)
    }
}

/// One Codable value in one JSON file (Hive build order: the shared store HivePattern listed as `json-file-store`).
/// A missing or unreadable file loads as nil (or the default you pass); `load` never deletes or rewrites it. `save`
/// makes the folder and writes atomically (a temporary file renamed over the old one), so a reader — the app or its
/// widget — sees the old file or the new one, never half of one.
public struct JSONFileStore<Value: Codable>: Sendable {
    /// How the file is locked on iOS while the device is locked; ignored elsewhere.
    public enum Protection: Sendable, Equatable {
        case none
        /// Readable after the first unlock since boot (background tasks and widgets can read it).
        case untilFirstUnlock
        /// Readable only while the device is unlocked.
        case complete
    }

    public let url: URL
    public let coding: JSONCoding
    public let protection: Protection

    public init(url: URL, coding: JSONCoding = .plain, protection: Protection = .none) {
        self.url = url
        self.coding = coding
        self.protection = protection
    }

    /// `Application Support/<path>` (e.g. `"HiveRounds/digest.json"`), or under `base` when given (tests).
    public static func applicationSupport(_ path: String, base: URL? = nil, coding: JSONCoding = .plain,
                                          protection: Protection = .none) -> JSONFileStore {
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return JSONFileStore(url: root.appendingPathComponent(path), coding: coding, protection: protection)
    }

    /// Whether a file (readable or not) is at `url`.
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The saved value, or nil when the file is missing or doesn't decode.
    public func load() -> Value? { coding.decode(Value.self, from: try? Data(contentsOf: url)) }

    /// The saved value, or `fallback` when the file is missing or doesn't decode.
    public func load(default fallback: @autoclosure () -> Value) -> Value { load() ?? fallback() }

    /// Writes `value` atomically, making the folder first.
    public func save(_ value: Value) throws {
        try write(coding.encoder().encode(value))
    }

    /// Writes already-encoded bytes the same way `save` does (for a value whose encoding the caller owns).
    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        switch protection {
        case .none: break
        case .untilFirstUnlock: options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        case .complete: options.insert(.completeFileProtection)
        }
        #endif
        try data.write(to: url, options: options)
    }

    /// Deletes the file; nothing to delete is fine.
    public func remove() { try? FileManager.default.removeItem(at: url) }
}

/// One Codable value as JSON bytes under one `UserDefaults` key (HivePattern `json-userdefaults-store`). Bytes that
/// are missing, not `Data`, or don't decode load as nil (or the default you pass).
public struct JSONDefaultsStore<Value: Codable> {
    public let key: String
    public let defaults: UserDefaults
    public let coding: JSONCoding

    public init(key: String, defaults: UserDefaults = .standard, coding: JSONCoding = .plain) {
        self.key = key
        self.defaults = defaults
        self.coding = coding
    }

    public func load() -> Value? { coding.decode(Value.self, from: defaults.data(forKey: key)) }

    public func load(default fallback: @autoclosure () -> Value) -> Value { load() ?? fallback() }

    public func save(_ value: Value) throws { defaults.set(try coding.encoder().encode(value), forKey: key) }

    public func remove() { defaults.removeObject(forKey: key) }
}
