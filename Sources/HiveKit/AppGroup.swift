import Foundation

/// The App Group container an app and its widget share (HivePattern: `containerURL(forSecurityApplicationGroupIdentifier:)`
/// was hand-rolled in HiveWorld, HiveTempo and HiveScore, each with its own fallback). An unsigned or simulator
/// build, the Mac app, or a build without the entitlement gets no container: `fallback` says what to use then, so an
/// app that moves here keeps the folder it used before.
public enum AppGroup {
    public enum Fallback: Sendable, Equatable {
        /// No folder: the caller skips the file (a widget snapshot nobody can read).
        case none
        /// The app's Application Support folder (made if missing).
        case applicationSupport
        /// The temporary folder.
        case temporary
    }

    /// The group's container, or the fallback folder (nil for `.none`). `container` is the lookup (tests replace it).
    public static func folder(_ id: String, fallback: Fallback = .none,
                              container: (String) -> URL? = defaultContainer) -> URL? {
        if let url = container(id) { return url }
        let fm = FileManager.default
        switch fallback {
        case .none:
            return nil
        case .applicationSupport:
            return (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        case .temporary:
            return fm.temporaryDirectory
        }
    }

    /// `path` (e.g. `"widget.json"` or `"score/latest.json"`) inside `folder(id, fallback:)`.
    public static func url(_ id: String, _ path: String, fallback: Fallback = .none,
                           container: (String) -> URL? = defaultContainer) -> URL? {
        folder(id, fallback: fallback, container: container)?.appendingPathComponent(path)
    }

    /// `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`; nil on Linux (no App Groups).
    public static func defaultContainer(_ id: String) -> URL? {
        #if canImport(Darwin)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        #else
        nil
        #endif
    }
}

extension JSONFileStore {
    /// `path` in the App Group `id` (see `AppGroup.url`); nil when there is no container and `fallback` is `.none`.
    public static func appGroup(_ id: String, _ path: String, fallback: AppGroup.Fallback = .none,
                                coding: JSONCoding = .plain, protection: Protection = .none,
                                container: (String) -> URL? = AppGroup.defaultContainer) -> JSONFileStore? {
        AppGroup.url(id, path, fallback: fallback, container: container)
            .map { JSONFileStore(url: $0, coding: coding, protection: protection) }
    }
}
