import Foundation
import AppKit
import CoreGraphics

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
    private var apiKey: String?
    
    // Retry configuration
    private let maxRetries = 3
    private let requestTimeout: TimeInterval = 15.0 // 15 seconds timeout as requested
    
    // Reference to AudioManager for network stress reporting
    private weak var audioManager: AudioManager?
    
    init(audioManager: AudioManager? = nil) {
        self.audioManager = audioManager
        loadAPIKey()
        checkAccessibilityPermission()
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
    
    private func checkAccessibilityPermission() {
        // Check if we have accessibility permission
        let trusted = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = trusted
            if !trusted {
                self.showAccessibilityAlert()
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
        guard let apiKey = apiKey else {
            logError("Transcription error: No API key provided")
            completion(.failure(.noAPIKey))
            return
        }
        
        DispatchQueue.main.async {
            self.isTranscribing = true
        }
        
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
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
        data.append("whisper-1\r\n".data(using: .utf8)!)
        
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
    
    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Permission Required"
            alert.informativeText = "WhisperDictate needs accessibility permission to simulate keyboard events. Please grant access in System Settings > Privacy & Security > Accessibility, then quit and relaunch WhisperDictate."
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
