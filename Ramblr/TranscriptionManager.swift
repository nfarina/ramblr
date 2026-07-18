import Foundation
import AppKit
import CoreGraphics
import UserNotifications
import AVFoundation
import RamblrKit

// `TranscriptionError` now lives in RamblrKit (shared with the iOS app).

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

    // Save-to-folder configuration
    @Published var saveFolderPath: String?
    @Published var saveFolderEnabled: Bool = false
    @Published var saveSubdirectoryFormat: String = "{year}/{month}/{day}"
    private let saveFolderPathKey = "TranscriptionSaveFolderPath"
    private let saveFolderEnabledKey = "TranscriptionSaveFolderEnabled"
    private let saveSubdirectoryFormatKey = "TranscriptionSaveSubdirectoryFormat"

    // Retry configuration
    private let maxRetries = 3
    private let requestTimeout: TimeInterval = 15.0 // 15 seconds timeout as requested
    private let maxUploadBytes = 19 * 1024 * 1024
    private let chunkSafetyMarginBytes = 64 * 1024
    private let minimumChunkDuration: TimeInterval = 0.1
    
    init() {
        loadAPIKey()
        loadGroqAPIKey()
        loadHistory()
        loadTranscriptionModel()
        loadSaveFolderSettings()
        cleanupStaleChunkFiles()
        // Do not prompt on startup unless auto-paste is enabled
        let autoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
        if autoPasteEnabled {
            checkAccessibilityPermission(shouldPrompt: true)
        } else {
            // Update state silently without prompting
            checkAccessibilityPermission(shouldPrompt: false)
        }
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

    var modelDisplayName: String {
        switch transcriptionModel {
        case "openai:whisper-1": return "Whisper (OpenAI)"
        case "groq:whisper-large-v3": return "Whisper (Groq)"
        case "openai:gpt-4o-transcribe": return "GPT-4o"
        case "openai:gpt-4o-mini-transcribe": return "GPT-4o mini"
        default: return transcriptionModel
        }
    }

    var hasRequiredAPIKey: Bool {
        if transcriptionModel.hasPrefix("groq:") {
            return !(groqApiKey ?? "").isEmpty
        } else {
            return !(apiKey ?? "").isEmpty
        }
    }

    var requiredKeyName: String {
        transcriptionModel.hasPrefix("groq:") ? "Groq" : "OpenAI"
    }

    var currentOpenAIKey: String { apiKey ?? "" }
    var currentGroqAPIKey: String { groqApiKey ?? "" }
    
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

                    if !error.isRetriable {
                        if case .noAPIKey = error {
                            self.updateStatus("Add your API key in Settings")
                        } else {
                            self.updateStatus("")
                        }
                        completion(nil)
                        return
                    }

                    if currentRetry < self.maxRetries {
                        currentRetry += 1
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
        let readFormat = audioFile.processingFormat

        // Output as 16-bit interleaved PCM WAV. This gives a predictable on-disk
        // size (bytesPerFrame = 2 * channels) and is plenty for speech transcription.
        // The processingFormat is typically non-interleaved Float32, where
        // mBytesPerFrame describes one channel only — relying on it leads to
        // chunks sized 2×+ too large for multi-channel sources.
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: readFormat.sampleRate,
            channels: readFormat.channelCount,
            interleaved: true
        ) else {
            throw TranscriptionError.fileError("Failed to create output format")
        }

        let outputBytesPerFrame = Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        if outputBytesPerFrame <= 0 {
            throw TranscriptionError.fileError("Unsupported audio format for chunking")
        }

        let maxChunkBytes = maxUploadBytes - chunkSafetyMarginBytes
        let maxFramesPerChunk = max(1, maxChunkBytes / outputBytesPerFrame)
        let minimumChunkFrames = AVAudioFramePosition(
            ceil(minimumChunkDuration * readFormat.sampleRate)
        )
        var chunkURLs: [URL] = []
        var chunkIndex = 0
        var completedSuccessfully = false
        defer {
            if !completedSuccessfully {
                cleanupChunkFiles(chunkURLs)
            }
        }

        while audioFile.framePosition < audioFile.length {
            let framesRemaining = audioFile.length - audioFile.framePosition
            let framesToRead = min(AVAudioFrameCount(maxFramesPerChunk), AVAudioFrameCount(framesRemaining))
            if framesToRead == 0 { break }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: framesToRead) else {
                throw TranscriptionError.fileError("Failed to allocate audio buffer")
            }

            try audioFile.read(into: buffer, frameCount: framesToRead)
            if buffer.frameLength == 0 { break }

            // AVAudioFile can expose a tiny decoder/converter tail at EOF. It is
            // too short for transcription and may produce a header-only WAV.
            if AVAudioFramePosition(buffer.frameLength) < minimumChunkFrames {
                logInfo("Skipping trailing audio chunk with only \(buffer.frameLength) frames")
                break
            }

            let chunkURL = makeChunkURL(index: chunkIndex)
            let chunkFile = try AVAudioFile(forWriting: chunkURL, settings: outputFormat.settings)
            try chunkFile.write(from: buffer)
            chunkFile.close()

            let writtenFile = try AVAudioFile(forReading: chunkURL)
            let writtenDuration = Double(writtenFile.length) / writtenFile.fileFormat.sampleRate
            writtenFile.close()
            guard writtenDuration >= minimumChunkDuration else {
                try? FileManager.default.removeItem(at: chunkURL)
                logInfo("Skipping trailing audio chunk with duration \(writtenDuration) seconds")
                break
            }

            if let chunkSize = fileSize(at: chunkURL), chunkSize > Int64(maxUploadBytes) {
                throw TranscriptionError.fileError("Chunk exceeded size limit")
            }

            chunkURLs.append(chunkURL)
            chunkIndex += 1
        }

        completedSuccessfully = true
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

    private func cleanupStaleChunkFiles() {
        let tempDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let staleBefore = Date().addingTimeInterval(-60 * 60)
        for url in contents where url.lastPathComponent.hasPrefix("ramblr-chunk-") {
            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if (modifiedAt ?? .distantPast) < staleBefore {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        return size
    }
    
    // Core request logic — delegates to RamblrKit's shared TranscriptionService.
    // Retry and chunking are still orchestrated by performTranscriptionWithRetry,
    // so this issues a single (non-retrying) request.
    private func performTranscriptionRequest(audioURL: URL, completion: @escaping (Result<String, TranscriptionError>) -> Void) {
        let model = TranscriptionModel(identifier: transcriptionModel)
        let authKey = (model.provider == .groq ? groqApiKey : apiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Fail fast if the chosen provider has no key
        guard !authKey.isEmpty else {
            logError("Transcription error: No API key provided for \(model.provider.displayName)")
            completion(.failure(.noAPIKey))
            return
        }

        DispatchQueue.main.async {
            self.isTranscribing = true
        }

        let service = TranscriptionService(requestTimeout: requestTimeout, maxRetries: 0) { message in
            logInfo(message)
        }

        Task {
            let result: Result<String, TranscriptionError>
            do {
                let text = try await service.transcribe(audioURL: audioURL, model: model, apiKey: authKey)
                result = .success(text)
            } catch let error as TranscriptionError {
                result = .failure(error)
            } catch {
                result = .failure(.networkError(error))
            }
            DispatchQueue.main.async {
                self.isTranscribing = false
                completion(result)
            }
        }
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
        
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents (all types) so we can restore them after pasting
        var previousItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                var typeData: [(NSPasteboard.PasteboardType, Data)] = []
                for type in item.types {
                    if let data = item.data(forType: type) {
                        typeData.append((type, data))
                    }
                }
                previousItems.append(typeData)
            }
        }

        // Put transcription text on the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V using CGEvent
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),   // 0x09 = kVK_ANSI_V
              let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            logError("Failed to create CGEvent for Cmd+V")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        logInfo("Successfully pasted text via Cmd+V")

        // Restore previous clipboard after a short delay
        let ourChangeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if pasteboard.changeCount == ourChangeCount {
                pasteboard.clearContents()
                for typeData in previousItems {
                    let item = NSPasteboardItem()
                    for (type, data) in typeData {
                        item.setData(data, forType: type)
                    }
                    pasteboard.writeObjects([item])
                }
                logInfo("Restored previous clipboard contents")
            }
        }
    }

    // MARK: - Output Handling

    /// Routes the transcription output based on the user's preference.
    /// When AutoPaste is enabled (default), the text is typed into the active app.
    /// Otherwise, the text is copied to the clipboard and a notification is shown.
    func handleTranscriptionOutput(_ text: String, clipboardOnly: Bool = false) {
        let isAutoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
        addToHistory(text)
        saveTranscriptionToFile(text)
        if isAutoPasteEnabled && !clipboardOnly {
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

    func addToHistory(_ text: String) {
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
    
    // MARK: - Save to Folder

    private func loadSaveFolderSettings() {
        saveFolderPath = UserDefaults.standard.string(forKey: saveFolderPathKey)
        saveFolderEnabled = UserDefaults.standard.bool(forKey: saveFolderEnabledKey)
        saveSubdirectoryFormat = UserDefaults.standard.string(forKey: saveSubdirectoryFormatKey) ?? "{year}/{month}/{day}"
    }

    func setSaveFolderPath(_ path: String?) {
        saveFolderPath = path
        if let path = path {
            UserDefaults.standard.set(path, forKey: saveFolderPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: saveFolderPathKey)
        }
        logInfo("TranscriptionManager: Save folder path set to \(path ?? "nil")")
    }

    func setSaveFolderEnabled(_ enabled: Bool) {
        saveFolderEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: saveFolderEnabledKey)
        logInfo("TranscriptionManager: Save folder enabled set to \(enabled)")
    }

    func setSaveSubdirectoryFormat(_ format: String) {
        saveSubdirectoryFormat = format
        UserDefaults.standard.set(format, forKey: saveSubdirectoryFormatKey)
        logInfo("TranscriptionManager: Save subdirectory format set to \(format)")
    }

    func saveTranscriptionToFile(_ text: String) {
        guard saveFolderEnabled,
              let basePath = saveFolderPath,
              !basePath.isEmpty else { return }

        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)

        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)
        let hour = String(format: "%02d", components.hour ?? 0)
        let minute = String(format: "%02d", components.minute ?? 0)
        let second = String(format: "%02d", components.second ?? 0)

        let subdirectory = saveSubdirectoryFormat
            .replacingOccurrences(of: "{year}", with: year)
            .replacingOccurrences(of: "{month}", with: month)
            .replacingOccurrences(of: "{day}", with: day)
            .replacingOccurrences(of: "{hour}", with: hour)
            .replacingOccurrences(of: "{minute}", with: minute)

        let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
        let directoryURL = subdirectory.isEmpty ? baseURL : baseURL.appendingPathComponent(subdirectory, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            logError("TranscriptionManager: Failed to create save directory: \(error)")
            return
        }

        let timestamp = "\(year)-\(month)-\(day)_\(hour)-\(minute)-\(second)"
        let slug = text.prefix(40)
            .components(separatedBy: .whitespacesAndNewlines)
            .prefix(5)
            .joined(separator: "-")
            .replacingOccurrences(of: "[^a-zA-Z0-9\\-]", with: "", options: .regularExpression)

        let filename = slug.isEmpty ? "\(timestamp).txt" : "\(timestamp)_\(slug).txt"
        let fileURL = directoryURL.appendingPathComponent(filename)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            logInfo("TranscriptionManager: Saved transcription to \(fileURL.path)")
        } catch {
            logError("TranscriptionManager: Failed to save transcription file: \(error)")
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
