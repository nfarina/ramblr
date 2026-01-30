import Foundation
import AppKit
import CoreGraphics
import UserNotifications
import AVFoundation

// Enumeration for transcription errors
enum TranscriptionError: Error {
    case networkError(Error)
    case apiError(Int, String)
    case noData
    case decodingError
    case noAPIKey
    case fileError(String)
    case timeout
    
    var description: String {
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
}

class TranscriptionManager: ObservableObject {
    @Published var isTranscribing = false
    @Published var hasAccessibilityPermission = false
    @Published var statusMessage = ""
    @Published var history: [String] = []
    private var apiKey: String?
    private var groqApiKey: String?
    private let modelDefaultsKey = "TranscriptionModel"
    // Provider-prefixed model id, e.g. "openai:whisper-1", "groq:whisper-large-v3"
    @Published private(set) var transcriptionModel: String = "openai:whisper-1"
    
    // Retry configuration
    private let maxRetries = 3
    private let requestTimeout: TimeInterval = 15.0 // 15 seconds timeout as requested
    private let maxUploadBytes = 19 * 1024 * 1024
    private let chunkSafetyMarginBytes = 64 * 1024
    
    // Reference to AudioManager for network stress reporting
    private weak var audioManager: AudioManager?
    
    init(audioManager: AudioManager? = nil) {
        self.audioManager = audioManager
        loadAPIKey()
        loadGroqAPIKey()
        loadHistory()
        loadTranscriptionModel()
        // Do not prompt on startup unless auto-paste is enabled
        let autoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
        if autoPasteEnabled {
            checkAccessibilityPermission(shouldPrompt: true)
        } else {
            // Update state silently without prompting
            checkAccessibilityPermission(shouldPrompt: false)
        }
    }
    
    func setAudioManager(_ audioManager: AudioManager) {
        self.audioManager = audioManager
    }
    
    private func loadAPIKey() {
        apiKey = UserDefaults.standard.string(forKey: "OpenAIAPIKey")
    }
    
    func setAPIKey(_ key: String) {
        apiKey = key
        UserDefaults.standard.set(key, forKey: "OpenAIAPIKey")
    }

    private func loadGroqAPIKey() {
        groqApiKey = UserDefaults.standard.string(forKey: "GroqAPIKey")
    }
    
    func setGroqAPIKey(_ key: String) {
        groqApiKey = key
        UserDefaults.standard.set(key, forKey: "GroqAPIKey")
    }

    private func loadTranscriptionModel() {
        if let stored = UserDefaults.standard.string(forKey: modelDefaultsKey) {
            // Migrate old values without provider prefix
            if stored.hasPrefix("openai:") || stored.hasPrefix("groq:") {
                transcriptionModel = stored
            } else if stored == "whisper-1" || stored == "gpt-4o-transcribe" || stored == "gpt-4o-mini-transcribe" {
                transcriptionModel = "openai:\(stored)"
            } else {
                transcriptionModel = "openai:whisper-1"
            }
        } else {
            transcriptionModel = "openai:whisper-1"
        }
    }

    func setTranscriptionModel(_ model: String) {
        transcriptionModel = model
        UserDefaults.standard.set(model, forKey: modelDefaultsKey)
        logInfo("Transcription model set to: \(model)")
    }
    
    func checkAccessibilityPermission(shouldPrompt: Bool = false) {
        // Check if we have accessibility permission
        let trusted = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = trusted
            if !trusted && shouldPrompt {
                self.showAccessibilityAlert()
            }
        }
    }
    
    // New method that incorporates retries and handles file chunking
    func transcribeWithRetry(audioURL: URL, completion: @escaping (String?) -> Void) {
        if shouldSplitFile(at: audioURL) {
            splitAndTranscribe(audioURL: audioURL, completion: completion)
            return
        }
        performTranscriptionWithRetry(audioURL: audioURL, statusPrefix: nil, completion: completion)
    }
    
    // Original transcribe method now calls transcribeWithRetry
    func transcribe(audioURL: URL, completion: @escaping (String?) -> Void) {
        transcribeWithRetry(audioURL: audioURL, completion: completion)
    }

    private func performTranscriptionWithRetry(audioURL: URL, statusPrefix: String?, completion: @escaping (String?) -> Void) {
        var currentRetry = 0
        let prefix = statusPrefix.map { "\($0): " } ?? ""

        updateStatus("\(prefix)Starting transcription...")

        func attemptTranscription() {
            logInfo("Attempting transcription (try \(currentRetry + 1) of \(self.maxRetries + 1))")

            if currentRetry > 0 {
                updateStatus("\(prefix)Retry \(currentRetry) of \(self.maxRetries)...")
            }

            self.performTranscriptionRequest(audioURL: audioURL) { result in
                switch result {
                case .success(let text):
                    self.updateStatus("")
                    completion(text)

                case .failure(let error):
                    logError("Transcription attempt \(currentRetry + 1) failed: \(error.description)")

                    if case .noAPIKey = error {
                        self.updateStatus("Add your API key in Settings")
                        completion(nil)
                        return
                    }

                    if currentRetry < self.maxRetries {
                        currentRetry += 1
                        self.audioManager?.reportNetworkStress(level: currentRetry)
                        let delay = pow(2.0, Double(currentRetry - 1))
                        self.updateStatus("\(prefix)Retry in \(Int(delay))s... (\(currentRetry)/\(self.maxRetries))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            attemptTranscription()
                        }
                    } else {
                        self.updateStatus("")
                        logError("Transcription failed after \(self.maxRetries + 1) attempts")
                        completion(nil)
                    }
                }
            }
        }

        attemptTranscription()
    }

    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionStatusChanged"),
                object: nil,
                userInfo: ["status": message]
            )
        }
    }

    private func shouldSplitFile(at url: URL) -> Bool {
        guard let fileSize = fileSize(at: url) else { return false }
        return fileSize > Int64(maxUploadBytes)
    }

    private func splitAndTranscribe(audioURL: URL, completion: @escaping (String?) -> Void) {
        updateStatus("Preparing large audio file...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let chunkURLs = try self.splitAudioFile(audioURL: audioURL)
                guard !chunkURLs.isEmpty else {
                    self.updateStatus("Audio file is empty")
                    completion(nil)
                    return
                }
                logInfo("Large audio split into \(chunkURLs.count) chunks")
                self.transcribeChunksWithRetry(chunkURLs, completion: completion)
            } catch {
                logError("Failed to split audio file: \(error)")
                self.updateStatus("Failed to prepare audio for upload")
                completion(nil)
            }
        }
    }

    private func transcribeChunksWithRetry(_ chunkURLs: [URL], completion: @escaping (String?) -> Void) {
        var results: [String] = []

        func finishAndCleanup(success: Bool) {
            cleanupChunkFiles(chunkURLs)
            if success {
                let combined = results
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                completion(combined)
            } else {
                completion(nil)
            }
        }

        func transcribeNext(index: Int) {
            if index >= chunkURLs.count {
                finishAndCleanup(success: true)
                return
            }

            let statusPrefix = "Part \(index + 1) of \(chunkURLs.count)"
            performTranscriptionWithRetry(audioURL: chunkURLs[index], statusPrefix: statusPrefix) { text in
                guard let text = text else {
                    finishAndCleanup(success: false)
                    return
                }
                results.append(text)
                transcribeNext(index: index + 1)
            }
        }

        transcribeNext(index: 0)
    }

    private func splitAudioFile(audioURL: URL) throws -> [URL] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        let streamDescription = format.streamDescription.pointee

        var bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        if bytesPerFrame == 0 {
            let bytesPerSample = Int(streamDescription.mBitsPerChannel) / 8
            bytesPerFrame = bytesPerSample * Int(streamDescription.mChannelsPerFrame)
        }
        if bytesPerFrame <= 0 {
            throw TranscriptionError.fileError("Unsupported audio format for chunking")
        }

        let maxChunkBytes = maxUploadBytes - chunkSafetyMarginBytes
        let maxFramesPerChunk = max(1, maxChunkBytes / bytesPerFrame)
        var chunkURLs: [URL] = []
        var chunkIndex = 0

        while audioFile.framePosition < audioFile.length {
            let framesRemaining = audioFile.length - audioFile.framePosition
            let framesToRead = min(AVAudioFrameCount(maxFramesPerChunk), AVAudioFrameCount(framesRemaining))
            if framesToRead == 0 { break }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw TranscriptionError.fileError("Failed to allocate audio buffer")
            }

            try audioFile.read(into: buffer, frameCount: framesToRead)
            if buffer.frameLength == 0 { break }

            let chunkURL = makeChunkURL(index: chunkIndex)
            let chunkFile = try AVAudioFile(forWriting: chunkURL, settings: format.settings)
            try chunkFile.write(from: buffer)

            if let chunkSize = fileSize(at: chunkURL), chunkSize > Int64(maxUploadBytes) {
                throw TranscriptionError.fileError("Chunk exceeded size limit")
            }

            chunkURLs.append(chunkURL)
            chunkIndex += 1
        }

        return chunkURLs
    }

    private func makeChunkURL(index: Int) -> URL {
        let tempDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let filename = "ramblr-chunk-\(UUID().uuidString)-\(index).wav"
        return tempDir.appendingPathComponent(filename)
    }

    private func cleanupChunkFiles(_ chunkURLs: [URL]) {
        for url in chunkURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        return size
    }
    
    // Core request logic extracted to a separate method
    private func performTranscriptionRequest(audioURL: URL, completion: @escaping (Result<String, TranscriptionError>) -> Void) {
        // Determine provider and model name
        let parts = transcriptionModel.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let provider = parts.count == 2 ? String(parts[0]) : "openai"
        let modelNameRaw = parts.count == 2 ? String(parts[1]) : transcriptionModel
        let useGroq = (provider == "groq")
        let selectedKey = useGroq ? groqApiKey : apiKey
        let authKey = selectedKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        // Fail fast if the chosen provider has no key
        guard !authKey.isEmpty else {
            let providerName = useGroq ? "Groq" : "OpenAI"
            logError("Transcription error: No API key provided for \(providerName)")
            completion(.failure(.noAPIKey))
            return
        }
        
        DispatchQueue.main.async {
            self.isTranscribing = true
        }
        
        // Groq uses OpenAI-compatible path under /openai
        let baseURL = useGroq ? "https://api.groq.com/openai" : "https://api.openai.com"
        let url = URL(string: "\(baseURL)/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")
        
        // Set timeout
        request.timeoutInterval = requestTimeout
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var data = Data()
        
        // Add audio file
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        
        do {
            let audioData = try Data(contentsOf: audioURL)
            let audioFileSize = audioData.count
            logInfo("Audio file size being sent to API: \(audioFileSize) bytes")
            data.append(audioData)
        } catch {
            logError("Error reading audio file: \(error)")
            DispatchQueue.main.async {
                self.isTranscribing = false
            }
            completion(.failure(.fileError(error.localizedDescription)))
            return
        }
        
        data.append("\r\n".data(using: .utf8)!)
        
        // Add model parameter
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        // Groq expects whisper-large-v3; OpenAI accepts whisper-1 or gpt-4o(-mini)-transcribe
        let modelForAPI: String = {
            if useGroq { return "whisper-large-v3" }
            return modelNameRaw
        }()
        data.append("\(modelForAPI)\r\n".data(using: .utf8)!)
        
        // Add temperature parameter for stability
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
        data.append("0.0\r\n".data(using: .utf8)!)
        
        // Add final boundary
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = data
        
        // Create a dedicated session with configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        config.waitsForConnectivity = true
        
        let session = URLSession(configuration: config)
        
        session.dataTask(with: request) { [weak self] data, response, error in
            // Always mark transcription as done on main thread
            DispatchQueue.main.async {
                self?.isTranscribing = false
            }
            
            // Handle session cleanup
            session.finishTasksAndInvalidate()
            
            // Handle errors
            if let error = error {
                let nsError = error as NSError
                
                // Special handling for timeout
                if nsError.domain == NSURLErrorDomain && 
                   (nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorNetworkConnectionLost) {
                    logError("Transcription timed out: \(error.localizedDescription)")
                    completion(.failure(.timeout))
                    return
                }
                
                logError("Transcription network error: \(error.localizedDescription)")
                logError("Error domain: \(nsError.domain), code: \(nsError.code)")
                completion(.failure(.networkError(error)))
                return
            }
            
            // Check HTTP status code
            if let httpResponse = response as? HTTPURLResponse {
                logInfo("Transcription API response status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode != 200 {
                    logError("Transcription API error: Non-200 status code (\(httpResponse.statusCode))")
                    
                    var errorMessage = "Unknown error"
                    
                    if let data = data, let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        logError("API error response: \(errorJson)")
                        if let errorObj = errorJson["error"] as? [String: Any], 
                           let message = errorObj["message"] as? String {
                            errorMessage = message
                            logError("Error message: \(message)")
                        }
                    }
                    
                    completion(.failure(.apiError(httpResponse.statusCode, errorMessage)))
                    return
                }
            }
            
            // Check for data
            guard let data = data else {
                logError("Transcription error: No data received from API")
                completion(.failure(.noData))
                return
            }
            
            // Parse response
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let text = json["text"] as? String {
                        logInfo("Transcription successful, received text of length: \(text.count)")
                        completion(.success(text))
                    } else {
                        logError("Transcription error: Response missing 'text' field")
                        logError("Full API response: \(json)")
                        completion(.failure(.decodingError))
                    }
                } else {
                    logError("Transcription error: Invalid JSON response")
                    
                    if let responseString = String(data: data, encoding: .utf8) {
                        logError("Raw API response: \(responseString)")
                    }
                    
                    completion(.failure(.decodingError))
                }
            } catch {
                logError("Transcription JSON parsing error: \(error)")
                
                if let responseString = String(data: data, encoding: .utf8) {
                    logError("Raw API response: \(responseString)")
                }
                
                completion(.failure(.decodingError))
            }
        }.resume()
    }
    
    func pasteText(_ text: String) {
        logInfo("Starting text paste operation")
        
        // First check if we have accessibility permission
        if !AXIsProcessTrusted() {
            logError("No accessibility permission")
            DispatchQueue.main.async {
                self.showAccessibilityAlert()
            }
            return
        }
        
        let script = """
        tell application "System Events"
            keystroke "\(text)"
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                logError("AppleScript error: \(error)")
                // If we get an error, recheck permissions as they might have been revoked
                DispatchQueue.main.async {
                    self.checkAccessibilityPermission()
                }
            } else {
                logInfo("Successfully typed text")
            }
        }
    }

    // MARK: - Output Handling

    /// Routes the transcription output based on the user's preference.
    /// When AutoPaste is enabled (default), the text is typed into the active app.
    /// Otherwise, the text is copied to the clipboard and a notification is shown.
    func handleTranscriptionOutput(_ text: String) {
        let isAutoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
        addToHistory(text)
        if isAutoPasteEnabled {
            // If auto-paste is on but we don't have permission, show prompt and fall back to copy
            if !AXIsProcessTrusted() {
                checkAccessibilityPermission(shouldPrompt: true)
                copyToClipboardAndNotify(text)
            } else {
                pasteText(text)
            }
        } else {
            copyToClipboardAndNotify(text)
        }
    }

    /// Copies the given text to the clipboard and posts a local notification to inform the user.
    private func copyToClipboardAndNotify(_ text: String) {
        logInfo("Copying transcription to clipboard")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.async {
            self.statusMessage = "Copied to clipboard"
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionStatusChanged"),
                object: nil,
                userInfo: ["status": "Copied to clipboard"]
            )
        }

        requestNotificationAuthorizationIfNeeded { authorized in
            guard authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Transcription copied to clipboard"
            let preview = text.prefix(80)
            content.body = preview.isEmpty ? "Ready to paste." : "\(preview)…"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil // deliver immediately
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    logError("Failed to deliver notification: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Requests user notification permission only if needed, then calls completion with current authorization state.
    private func requestNotificationAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // For LSUIElement (agent) apps, the system may not show the permission prompt
                // unless the app is temporarily activated. Elevate policy briefly to ensure
                // the prompt appears, then restore the prior policy.
                DispatchQueue.main.async {
                    let previousPolicy = NSApp.activationPolicy()
                    let shouldElevate = previousPolicy != .regular
                    if shouldElevate {
                        _ = NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        DispatchQueue.main.async {
                            if shouldElevate {
                                _ = NSApp.setActivationPolicy(previousPolicy)
                            }
                            completion(granted)
                        }
                    }
                }
            case .authorized, .provisional:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    // MARK: - History

    private let historyKey = "TranscriptionHistory"
    private let historyLimit = 10

    private func loadHistory() {
        if let stored = UserDefaults.standard.array(forKey: historyKey) as? [String] {
            DispatchQueue.main.async {
                self.history = stored
            }
        }
    }

    private func persistHistory() {
        UserDefaults.standard.set(history, forKey: historyKey)
    }

    private func addToHistory(_ text: String) {
        DispatchQueue.main.async {
            // Remove existing duplicate if present, then insert at top
            if let existingIndex = self.history.firstIndex(of: text) {
                self.history.remove(at: existingIndex)
            }
            self.history.insert(text, at: 0)
            if self.history.count > self.historyLimit {
                self.history = Array(self.history.prefix(self.historyLimit))
            }
            self.persistHistory()
        }
    }

    func copyFromHistory(_ text: String) {
        copyToClipboardAndNotify(text)
    }

    func clearHistory() {
        DispatchQueue.main.async {
            self.history.removeAll()
            UserDefaults.standard.removeObject(forKey: self.historyKey)
            self.statusMessage = "History cleared"
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionStatusChanged"),
                object: nil,
                userInfo: ["status": "History cleared"]
            )
        }
    }
    
    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Permission Required"
            alert.informativeText = "Ramblr needs accessibility permission to simulate keyboard events. Please grant access in System Settings > Privacy & Security > Accessibility, then quit and relaunch Ramblr."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
