import Foundation

/// One way to answer a prompt: Apple's on-device model, the Mac hub, and so on. HiveRounds and HiveBeat each hand
/// `HiveAI` a list of these, best first.
public protocol HiveAIEngine: Sendable {
    /// Short stable name, reported in `HiveAIResult.answer(_:engine:)` ("on-device").
    var name: String { get }
    /// nil when the engine can run now; otherwise why not, in words for the person. Async because an engine such as
    /// the hub has to ping the network to know.
    func unavailableReason() async -> String?
    func answer(_ prompt: String, instructions: String) async throws -> String
}

public enum HiveAIResult: Equatable, Sendable {
    /// An engine wrote the answer.
    case answer(String, engine: String)
    /// No engine could: the text to copy into the person's own Claude or ChatGPT (see `OpenInApp`).
    case pastePrompt(String)
}

/// The on-device-AI-then-paste-prompt chain: try each engine in order, and when none answers hand back a prompt the
/// person can paste into their own Claude or ChatGPT. Moved out of HiveRounds so HiveBeat shares it.
public struct HiveAI: Sendable {
    private let engines: [any HiveAIEngine]

    public init(engines: [any HiveAIEngine]) {
        self.engines = engines
    }

    /// Engines are tried in order. One whose `unavailableReason()` is non-nil is skipped; one that throws falls
    /// through to the next. If the task is cancelled, or an engine throws `CancellationError`, the chain stops at
    /// once without calling later engines and the result is `.pastePrompt` (the result is non-throwing, and a
    /// cancelled caller ignores it anyway).
    public func answer(_ prompt: String, instructions: String) async -> HiveAIResult {
        for engine in engines {
            if Task.isCancelled { break }
            if await engine.unavailableReason() != nil { continue }
            do {
                return .answer(try await engine.answer(prompt, instructions: instructions), engine: engine.name)
            } catch is CancellationError {
                break
            } catch {
                continue
            }
        }
        return .pastePrompt(instructions + "\n\n" + prompt)
    }
}
