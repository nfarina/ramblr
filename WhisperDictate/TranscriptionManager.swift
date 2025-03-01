import Foundation
import AppKit
import CoreGraphics

class TranscriptionManager: ObservableObject {
    @Published var isTranscribing = false
    @Published var hasAccessibilityPermission = false
    private var apiKey: String?
    
    init() {
        loadAPIKey()
        checkAccessibilityPermission()
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
    
    func transcribe(audioURL: URL, completion: @escaping (String?) -> Void) {
        guard let apiKey = apiKey else {
            completion(nil)
            return
        }
        
        isTranscribing = true
        
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var data = Data()
        
        // Add audio file
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        data.append(try! Data(contentsOf: audioURL))
        data.append("\r\n".data(using: .utf8)!)
        
        // Add model parameter
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        data.append("whisper-1\r\n".data(using: .utf8)!)
        
        // Add final boundary
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = data
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isTranscribing = false
                
                if let error = error {
                    print("Transcription network error: \(error.localizedDescription)")
                    print("Underlying error: \(error)")
                    completion(nil)
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    print("Transcription API response status: \(httpResponse.statusCode)")
                    if httpResponse.statusCode != 200 {
                        print("Transcription API error: Non-200 status code")
                        if let data = data, let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            print("API error response: \(errorJson)")
                        }
                        completion(nil)
                        return
                    }
                }
                
                guard let data = data else {
                    print("Transcription error: No data received from API")
                    completion(nil)
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let text = json["text"] as? String {
                            print("Transcription successful, received text of length: \(text.count)")
                            completion(text)
                        } else {
                            print("Transcription error: Response missing 'text' field")
                            print("Full API response: \(json)")
                            completion(nil)
                        }
                    } else {
                        print("Transcription error: Invalid JSON response")
                        if let responseString = String(data: data, encoding: .utf8) {
                            print("Raw API response: \(responseString)")
                        }
                        completion(nil)
                    }
                } catch {
                    print("Transcription JSON parsing error: \(error)")
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("Raw API response: \(responseString)")
                    }
                    completion(nil)
                }
            }
        }.resume()
    }
    
    func pasteText(_ text: String) {
        print("Starting pasteText...")
        
        // First check if we have accessibility permission
        if !AXIsProcessTrusted() {
            print("No accessibility permission")
            showAccessibilityAlert()
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
                print("AppleScript error:", error)
                // If we get an error, recheck permissions as they might have been revoked
                checkAccessibilityPermission()
            } else {
                print("Successfully typed text")
            }
        }
    }
    
    private func showAccessibilityAlert() {
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
