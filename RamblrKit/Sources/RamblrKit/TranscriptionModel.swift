import Foundation

/// A transcription provider + model, encoded as the macOS app's
/// provider-prefixed string format, e.g. `"openai:whisper-1"` or
/// `"groq:whisper-large-v3"`.
///
/// Keeping the same string encoding means the iOS and macOS apps store
/// settings identically and can eventually share defaults via iCloud / an
/// App Group with no translation.
public struct TranscriptionModel: Equatable, Hashable, Sendable {
    public enum Provider: String, Sendable {
        case openai
        case groq

        public var displayName: String {
            switch self {
            case .openai: return "OpenAI"
            case .groq: return "Groq"
            }
        }

        /// OpenAI-compatible base URL (Groq exposes the same path under `/openai`).
        public var baseURL: URL {
            switch self {
            case .openai: return URL(string: "https://api.openai.com")!
            case .groq: return URL(string: "https://api.groq.com/openai")!
            }
        }
    }

    public let provider: Provider
    /// The model name the API expects, e.g. `whisper-1`, `whisper-large-v3`.
    public let modelName: String

    public init(provider: Provider, modelName: String) {
        self.provider = provider
        self.modelName = modelName
    }

    /// The provider-prefixed identifier, e.g. `"groq:whisper-large-v3"`.
    public var identifier: String { "\(provider.rawValue):\(modelName)" }

    public var displayName: String {
        switch identifier {
        case "openai:whisper-1": return "Whisper (OpenAI)"
        case "groq:whisper-large-v3": return "Whisper (Groq)"
        case "openai:gpt-4o-transcribe": return "GPT-4o Transcribe"
        case "openai:gpt-4o-mini-transcribe": return "GPT-4o mini Transcribe"
        default: return modelName
        }
    }

    /// Parse a provider-prefixed identifier. Falls back to OpenAI Whisper for
    /// legacy/unknown values, matching the macOS app's tolerant parsing.
    public init(identifier: String) {
        let parts = identifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let provider = Provider(rawValue: String(parts[0])) {
            self.provider = provider
            self.modelName = String(parts[1])
        } else {
            self.provider = .openai
            self.modelName = "whisper-1"
        }
    }

    // MARK: - Built-in options

    public static let openAIWhisper = TranscriptionModel(provider: .openai, modelName: "whisper-1")
    public static let groqWhisper = TranscriptionModel(provider: .groq, modelName: "whisper-large-v3")

    /// Models offered in the iOS picker.
    public static let presets: [TranscriptionModel] = [.groqWhisper, .openAIWhisper]
}
