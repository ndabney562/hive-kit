#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple's on-device model (Foundation Models). Nothing leaves the phone. Moved from HiveRounds' `OnDeviceWriter`.
public struct OnDeviceEngine: HiveAIEngine {
    private let guardrails: SystemLanguageModel.Guardrails

    /// `.permissiveContentTransformations` suits rewriting text the person chose (the default guardrails refuse
    /// medical papers: "May contain sensitive content"); it works only for plain-text answers.
    public init(guardrails: SystemLanguageModel.Guardrails = .default) {
        self.guardrails = guardrails
    }

    public var name: String { "on-device" }

    public func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This iPhone can't run Apple Intelligence. Use your Claude or ChatGPT below."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri, or use your Claude or ChatGPT below."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading. Try again in a few minutes, or use your Claude or ChatGPT below."
        case .unavailable: "Apple Intelligence isn't available right now. Use your Claude or ChatGPT below."
        }
    }

    public func answer(_ prompt: String, instructions: String) async throws -> String {
        let model = SystemLanguageModel(guardrails: guardrails)
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt).content
    }
}
#endif
