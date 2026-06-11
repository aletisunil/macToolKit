import Foundation
import FoundationModels

enum RewriteError: LocalizedError {
    case modelUnavailable(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): "Apple Intelligence unavailable: \(reason)"
        case .emptyResult: "The model returned no text."
        }
    }
}

/// On-device rewrite via Apple Intelligence (FoundationModels).
final class RewriteEngine: Sendable {
    static func availabilityDescription() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac is not eligible for Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled. Turn it on in System Settings."
        case .unavailable(.modelNotReady):
            return "The model is still downloading. Try again shortly."
        case .unavailable:
            return "Apple Intelligence is unavailable."
        }
    }

    func rewrite(_ text: String, using trigger: RewriteTrigger) async throws -> String {
        if let reason = Self.availabilityDescription() {
            throw RewriteError.modelUnavailable(reason)
        }

        let prompt: String
        if trigger.prompt.contains("{{text}}") {
            prompt = trigger.prompt.replacingOccurrences(of: "{{text}}", with: text)
        } else {
            prompt = trigger.prompt + "\n\n" + text
        }

        let session = LanguageModelSession(
            instructions: "You are a text rewriting tool. Reply with the rewritten text only — no preamble, no explanations, no surrounding quotes.")
        let response = try await session.respond(to: prompt)
        let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw RewriteError.emptyResult }
        return result
    }
}
