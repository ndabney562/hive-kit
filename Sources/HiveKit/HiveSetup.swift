import Foundation

/// First-launch setup for a Hive app (Hive build order #35, Onboard 60): only the steps the app needs, one at a time,
/// with progress ("Step 2 of 3"), the reason for each, and what iOS will ask before it asks. Progress is saved after
/// every step, so setup interrupted by a quit or a phone call picks up where it stopped. Steps already true on the
/// device (signed in, notifications allowed) count as done without asking. Its screen is hive-design's
/// `HiveSetupView`; `HiveSetup.problems` is the check each app's tests run on its steps.
public struct SetupStep: Identifiable, Equatable, Sendable {
    public var id: String
    /// "Sign in to GitHub"
    public var title: String
    /// Why the app needs it, in one or two plain sentences.
    public var why: String
    /// What iOS will show, for a step that triggers a system permission prompt ("iOS asks: Allow notifications?").
    public var permission: String?
    /// A required step has no "Not now".
    public var required: Bool
    /// The button: "Sign in", "Allow", "Check".
    public var action: String

    public init(id: String, title: String, why: String, permission: String? = nil, required: Bool = false,
                action: String) {
        self.id = id
        self.title = title
        self.why = why
        self.permission = permission
        self.required = required
        self.action = action
    }
}

public enum SetupState: String, Codable, Sendable {
    case todo, done, skipped
}

public struct HiveSetup: Equatable, Sendable {
    public var steps: [SetupStep]
    public private(set) var states: [String: SetupState]
    /// Some progress came from an earlier, unfinished run: the screen says "Welcome back".
    public private(set) var resumed: Bool

    public init(steps: [SetupStep], states: [String: SetupState] = [:], resumed: Bool = false) {
        self.steps = steps
        self.states = states.filter { id, _ in steps.contains { $0.id == id } }
        self.resumed = resumed
    }

    public func state(_ id: String) -> SetupState { states[id] ?? .todo }

    /// The first step still to do; nil when setup is finished.
    public var current: SetupStep? { steps.first { state($0.id) == .todo } }
    public var finished: Bool { current == nil }

    /// "Step 2 of 3" (the step on screen), or "All set".
    public var progressText: String {
        guard let current, let i = steps.firstIndex(of: current) else { return "All set" }
        return "Step \(i + 1) of \(steps.count)"
    }

    /// 0...1 for a progress bar: the share of steps already done or skipped.
    public var fraction: Double {
        steps.isEmpty ? 1 : Double(steps.filter { state($0.id) != .todo }.count) / Double(steps.count)
    }

    /// "Welcome back: 1 of 3 done. Pick up where you left off." after an interrupted setup, else nil.
    public var resumeNote: String? {
        guard resumed, !finished else { return nil }
        let done = steps.filter { state($0.id) != .todo }.count
        return "Welcome back: \(done) of \(steps.count) done. Pick up where you left off."
    }

    public mutating func markDone(_ id: String) { states[id] = .done }

    /// "Not now". A required step can't be skipped.
    public mutating func skip(_ id: String) {
        guard let step = steps.first(where: { $0.id == id }), !step.required else { return }
        states[id] = .skipped
    }

    /// The device's real state: true marks a step done; false reopens a step marked done that no longer holds
    /// (signed out since). A skipped step stays skipped.
    public mutating func sync(_ actual: [String: Bool]) {
        for (id, holds) in actual where steps.contains(where: { $0.id == id }) {
            if holds { states[id] = .done } else if states[id] == .done { states[id] = .todo }
        }
    }

    // MARK: - Saved progress

    public static func key(app: String) -> String { "hive.setup.\(app)" }

    /// Whether setup was ever started on this device.
    public static func started(app: String, defaults: UserDefaults) -> Bool {
        defaults.dictionary(forKey: key(app: app)) != nil
    }

    /// The saved progress for these steps (unknown or unreadable entries are dropped).
    public static func load(app: String, steps: [SetupStep], defaults: UserDefaults) -> HiveSetup {
        let raw = defaults.dictionary(forKey: key(app: app)) as? [String: String] ?? [:]
        let states = raw.compactMapValues(SetupState.init(rawValue:))
        let setup = HiveSetup(steps: steps, states: states)
        return HiveSetup(steps: steps, states: setup.states, resumed: !setup.states.isEmpty)
    }

    public func save(app: String, defaults: UserDefaults) {
        defaults.set(states.mapValues(\.rawValue), forKey: Self.key(app: app))
    }

    // MARK: - The check each app's tests run

    /// An empty result means the steps are good: unique ids, every step says why, a permission step says what iOS
    /// will ask, button titles are short, and there are at most 5 steps (minimum setup only).
    public static func problems(_ steps: [SetupStep]) -> [String] {
        var out: [String] = []
        if steps.isEmpty { out.append("no steps") }
        if steps.count > 5 { out.append("\(steps.count) steps: keep setup to the minimum (5 at most)") }
        var seen = Set<String>()
        for s in steps {
            if !seen.insert(s.id).inserted { out.append("\(s.id): id used twice") }
            if s.title.trimmingCharacters(in: .whitespaces).isEmpty { out.append("\(s.id): no title") }
            if s.why.trimmingCharacters(in: .whitespaces).count < 20 { out.append("\(s.id): say why in a sentence") }
            if let p = s.permission, p.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("\(s.id): permission text is empty")
            }
            if s.action.isEmpty || s.action.count > 16 { out.append("\(s.id): button title should be 1-16 characters") }
        }
        return out
    }
}
