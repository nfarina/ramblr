import Foundation

/// Cross-platform Whisper transcription client for the OpenAI and Groq
/// (OpenAI-compatible) audio transcription endpoints.
///
/// This is a direct, async/await port of the request-building and
/// response-parsing logic in the macOS app's `TranscriptionManager`. Keeping
/// it free of AppKit/UIKit lets both apps share one networking core.
public struct TranscriptionService: Sendable {

    /// Optional log sink so the host app can route messages into its own logger.
    public typealias LogHandler = @Sendable (String) -> Void

    public var requestTimeout: TimeInterval
    public var maxRetries: Int
    private let log: LogHandler

    public init(
        requestTimeout: TimeInterval = 15.0,
        maxRetries: Int = 3,
        log: @escaping LogHandler = { _ in }
    ) {
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.log = log
    }

    // MARK: - Public API

    /// Transcribe an audio file, retrying transient failures with exponential backoff.
    /// - Returns: The transcribed text, trimmed of surrounding whitespace.
    public func transcribeWithRetry(
        audioURL: URL,
        model: TranscriptionModel,
        apiKey: String
    ) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await transcribe(audioURL: audioURL, model: model, apiKey: apiKey)
            } catch let error as TranscriptionError {
                attempt += 1
                guard error.isRetriable, attempt <= maxRetries else { throw error }
                // Exponential backoff: 1s, 2s, 4s…
                let delay = pow(2.0, Double(attempt - 1))
                log("Transcription attempt \(attempt) failed (\(error.description)); retrying in \(Int(delay))s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Perform a single transcription request.
    public func transcribe(
        audioURL: URL,
        model: TranscriptionModel,
        apiKey: String
    ) async throws -> String {
        let authKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authKey.isEmpty else {
            log("Transcription error: No API key provided for \(model.provider.displayName)")
            throw TranscriptionError.noAPIKey
        }

        let url = model.provider.baseURL.appendingPathComponent("v1/audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            log("Error reading audio file: \(error)")
            throw TranscriptionError.fileError(error.localizedDescription)
        }

        let filename = audioURL.lastPathComponent
        let mimeType = Self.mimeType(for: audioURL.pathExtension)
        // Groq requires whisper-large-v3 regardless of stored model name.
        let modelForAPI = model.provider == .groq ? "whisper-large-v3" : model.modelName

        request.httpBody = Self.multipartBody(
            boundary: boundary,
            audioData: audioData,
            filename: filename,
            mimeType: mimeType,
            model: modelForAPI
        )
        log("Audio file size being sent to API: \(audioData.count) bytes")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorNetworkConnectionLost {
                log("Transcription timed out: \(error.localizedDescription)")
                throw TranscriptionError.timeout
            }
            log("Transcription network error: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
            throw TranscriptionError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse {
            log("Transcription API response status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                var message = "Unknown error"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = json["error"] as? [String: Any],
                   let msg = errorObj["message"] as? String {
                    message = msg
                }
                log("Transcription API error (\(httpResponse.statusCode)): \(message)")
                throw TranscriptionError.apiError(httpResponse.statusCode, message)
            }
        }

        guard !data.isEmpty else {
            log("Transcription error: No data received from API")
            throw TranscriptionError.noData
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            log("Transcription error: response missing 'text' field")
            throw TranscriptionError.decodingError
        }

        log("Transcription successful, received text of length: \(text.count)")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    static func multipartBody(
        boundary: String,
        audioData: Data,
        filename: String,
        mimeType: String,
        model: String
    ) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(string.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(audioData)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        // Temperature 0 for deterministic, stable output (matches macOS app).
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n")
        append("0.0\r\n")

        append("--\(boundary)--\r\n")
        return data
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }
}
