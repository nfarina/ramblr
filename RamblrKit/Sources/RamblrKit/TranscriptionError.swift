import Foundation

/// Errors surfaced by ``TranscriptionService``.
///
/// Ported from the macOS app's `TranscriptionManager` so both platforms share
/// identical error semantics.
public enum TranscriptionError: Error, LocalizedError {
    case networkError(Error)
    case apiError(Int, String)
    case noData
    case decodingError
    case noAPIKey
    case fileError(String)
    case timeout

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let code, let message):
            return "API error (code \(code)): \(message)"
        case .noData:
            return "No data received from API"
        case .decodingError:
            return "Failed to decode API response"
        case .noAPIKey:
            return "No API key provided"
        case .fileError(let message):
            return "File error: \(message)"
        case .timeout:
            return "Request timed out"
        }
    }

    /// Whether retrying the request might succeed (transient failures).
    public var isRetriable: Bool {
        switch self {
        case .timeout, .networkError, .noData:
            return true
        case .apiError(let code, _):
            // Retry on rate limits and server errors, not client errors.
            return code == 429 || (500...599).contains(code)
        case .decodingError, .noAPIKey, .fileError:
            return false
        }
    }
}
