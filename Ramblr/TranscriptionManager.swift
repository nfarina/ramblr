import Foundation
import AppKit
import CoreGraphics
import UserNotifications

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
    
    // Reference to AudioManager for network stress reporting
    private weak var audioManager: AudioManager?
    
    init(audioManager: AudioManager? = nil) {
        self.audioManager = audioManager
        loadAPIKey()
        loadGroqAPIKey()
        loadHistory()
        loadTranscriptionModel()
        // Do not prompt on startup unless auto-paste is enabled (default: true)
        // We also rely on notifications now, so we don't want to spam on launch.
        // let autoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? true
        // if autoPasteEnabled {
        //    checkAccessibilityPermission(shouldPrompt: false) // Silent check only
            checkAccessibilityPermission(shouldPrompt: false)
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
                self.showAccessibilityNotification()
            }
        }
    }
    
    // New method that incorporates retries
    func transcribeWithRetry(audioURL: URL, completion: @escaping (String?) -> Void) {
        var currentRetry = 0
        
        // Report starting status
        DispatchQueue.main.async {
            self.statusMessage = "Starting transcription..."
            
            // Also notify any observers
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionStatusChanged"),
                object: nil,
                userInfo: ["status": "Starting transcription..."]
            )
        }
        
        // Function to attempt transcription with retries
        func attemptTranscription() {
            logInfo("Attempting transcription (try \(currentRetry + 1) of \(self.maxRetries + 1))")
            
            // Update status message
            if currentRetry > 0 {
                let statusMsg = "Retry \(currentRetry) of \(self.maxRetries)..."
                DispatchQueue.main.async {
                    self.statusMessage = statusMsg
                    
                    // Also notify any observers
                    NotificationCenter.default.post(
                        name: NSNotification.Name("TranscriptionStatusChanged"),
                        object: nil,
                        userInfo: ["status": statusMsg]
                    )
                }
            }
            
            self.performTranscriptionRequest(audioURL: audioURL) { result in
                switch result {
                case .success(let text):
                    // Success - clear status and return text
                    DispatchQueue.main.async {
                        self.statusMessage = ""
                        
                        // Also notify any observers
                        NotificationCenter.default.post(
                            name: NSNotification.Name("TranscriptionStatusChanged"),
                            object: nil,
                            userInfo: ["status": ""]
                        )
                    }
                    completion(text)
                    
                case .failure(let error):
                    // Log the error
                    logError("Transcription attempt \(currentRetry + 1) failed: \(error.description)")
                    
                    // Do not retry if we are missing API credentials
                    if case .noAPIKey = error {
                        DispatchQueue.main.async {
                            self.statusMessage = "Add your API key in Settings"
                            NotificationCenter.default.post(
                                name: NSNotification.Name("TranscriptionStatusChanged"),
                                object: nil,
                                userInfo: ["status": "Add your API key in Settings"]
                            )
                        }
                        completion(nil)
                        return
                    }
                    
                    // Check if we can retry
                    if currentRetry < self.maxRetries {
                        currentRetry += 1
                        
                        // Report network stress to AudioManager
                        self.audioManager?.reportNetworkStress(level: currentRetry)
                        
                        // Calculate exponential backoff delay: 1s, 2s, 4s, etc.
                        let delay = pow(2.0, Double(currentRetry - 1))
                        
                        // Update status message
                        let statusMsg = "Retry in \(Int(delay))s... (\(currentRetry)/\(self.maxRetries))"
                        DispatchQueue.main.async {
                            self.statusMessage = statusMsg
                            
                            // Also notify any observers
                            NotificationCenter.default.post(
                                name: NSNotification.Name("TranscriptionStatusChanged"),
                                object: nil,
                                userInfo: ["status": statusMsg]
                            )
                        }
                        
                        // Schedule retry with backoff
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            attemptTranscription()
                        }
                    } else {
                        // No more retries
                        DispatchQueue.main.async {
                            self.statusMessage = ""
                            
                            // Also notify any observers
                            NotificationCenter.default.post(
                                name: NSNotification.Name("TranscriptionStatusChanged"),
                                object: nil,
                                userInfo: ["status": ""]
                            )
                        }
                        logError("Transcription failed after \(self.maxRetries + 1) attempts")
                        completion(nil)
                    }
                }
            }
        }
        
        // Start the first attempt
        attemptTranscription()
    }
    
    // Original transcribe method now calls transcribeWithRetry
    func transcribe(audioURL: URL, completion: @escaping (String?) -> Void) {
        transcribeWithRetry(audioURL: audioURL, completion: completion)
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
        logInfo("Starting auto-paste operation")
        
        // First check if we have accessibility permission
        if !AXIsProcessTrusted() {
            logError("No accessibility permission")
            DispatchQueue.main.async {
                self.showAccessibilityNotification()
            }
            return
        }
        
        // 1. SAVE CLIPBOARD
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }
        
        // 2. SET TRANSCRIPTION
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // 3. SIMULATE CMD+V
        // Using CGEvent for reliable system-wide input
        let source = CGEventSource(stateID: .hidSystemState)
        
        // 'v' key code is 9
        let vKeyCode: CGKeyCode = 9
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        
        // Add Command modifier
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        
        logInfo("Simulated Command+V")
        
        // 4. RESTORE CLIPBOARD (Delayed)
        // We need to wait long enough for the active application to process the paste command.
        // 1.0s is safer to ensure we don't restore before the paste happens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            logInfo("Restoring original clipboard content")
            if let saved = savedItems {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
        }
    }

    // MARK: - Output Handling

    /// Routes the transcription output based on the user's preference.
    /// When AutoPaste is enabled (default), the text is typed into the active app.
    /// Otherwise, the text is copied to the clipboard and a notification is shown.
    func handleTranscriptionOutput(_ text: String) {
        let isAutoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? true
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
    
    private func showAccessibilityNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Permission Required"
        content.body = "Ramblr needs accessibility permission to Paste. Click here to open System Settings."
        content.sound = .default
        content.userInfo = ["action": "open_accessibility"]
        
        let request = UNNotificationRequest(identifier: "accessibility_permission", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                logError("Failed to show notification: \(error)")
            }
        }
    }
}
