import Foundation
import Combine

struct RewriteTrigger: Codable, Identifiable, Equatable {
    var id: UUID
    /// Typed at the end of a text field to fire the rewrite, e.g. ";;fix".
    var word: String
    /// Prompt sent to the model; "{{text}}" is replaced with the field text.
    var prompt: String

    init(id: UUID = UUID(), word: String, prompt: String) {
        self.id = id
        self.word = word
        self.prompt = prompt
    }
}

@MainActor
final class TriggerStore: ObservableObject {
    @Published var triggers: [RewriteTrigger] {
        didSet { save() }
    }

    private static let key = "rewriteTriggers"

    static let defaultTriggers: [RewriteTrigger] = [
        RewriteTrigger(word: ";;fix",
                       prompt: "Fix all spelling, typo and grammar mistakes in the following text. Keep the wording, tone and meaning unchanged. Output only the corrected text.\n\n{{text}}"),
        RewriteTrigger(word: ";;tight",
                       prompt: "Rewrite the following text to be concise and clear. Preserve the meaning and tone. Output only the rewritten text.\n\n{{text}}"),
        RewriteTrigger(word: ";;prof",
                       prompt: "Rewrite the following text in a polite, professional tone. Output only the rewritten text.\n\n{{text}}"),
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([RewriteTrigger].self, from: data) {
            triggers = saved
        } else {
            triggers = Self.defaultTriggers
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(triggers) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Longest trigger word length — bounds the typing buffer.
    var maxWordLength: Int {
        triggers.map(\.word.count).max() ?? 0
    }

    func match(suffixOf buffer: String) -> RewriteTrigger? {
        triggers.first { !$0.word.isEmpty && buffer.hasSuffix($0.word) }
    }
}
