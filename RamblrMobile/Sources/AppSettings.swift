import Foundation
import Combine
import RamblrKit

/// Persisted user settings, backed by UserDefaults.
///
/// Keys intentionally match the macOS app so settings can later be shared
/// (e.g. via an App Group or iCloud key-value store) without migration.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    enum Key {
        static let openAIKey = "OpenAIAPIKey"
        static let groqKey = "GroqAPIKey"
        static let model = "TranscriptionModel"
    }

    @Published var openAIKey: String {
        didSet { defaults.set(openAIKey, forKey: Key.openAIKey) }
    }
    @Published var groqKey: String {
        didSet { defaults.set(groqKey, forKey: Key.groqKey) }
    }
    @Published var model: TranscriptionModel {
        didSet { defaults.set(model.identifier, forKey: Key.model) }
    }

    init() {
        openAIKey = defaults.string(forKey: Key.openAIKey) ?? ""
        groqKey = defaults.string(forKey: Key.groqKey) ?? ""
        let stored = defaults.string(forKey: Key.model) ?? TranscriptionModel.groqWhisper.identifier
        model = TranscriptionModel(identifier: stored)
    }

    /// The API key for the currently selected provider, or empty if unset.
    var activeKey: String {
        switch model.provider {
        case .openai: return openAIKey
        case .groq: return groqKey
        }
    }

    /// Whether the selected provider has a usable key.
    var isConfigured: Bool {
        !activeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
