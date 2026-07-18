import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

class RecordingCoordinator: ObservableObject {
    private var audioManager: AudioManager
    private var transcriptionManager: TranscriptionManager
    private var mediaPlaybackManager: MediaPlaybackManager
    private var recordingStore: RecordingStore
    private var notificationObserver: NSObjectProtocol?
    private var lastRecordingURL: URL? // Store the last recording URL for retry
    private var clipboardOnlyRecording = false
    private var cancellables = Set<AnyCancellable>()

    @Published var transcriptionStatus: String = ""

    init(
        audioManager: AudioManager,
        transcriptionManager: TranscriptionManager,
        mediaPlaybackManager: MediaPlaybackManager,
        recordingStore: RecordingStore
    ) {
        logInfo("RecordingCoordinator: Initializing")
        self.audioManager = audioManager
        self.transcriptionManager = transcriptionManager
        self.mediaPlaybackManager = mediaPlaybackManager
        self.recordingStore = recordingStore

        // Observe audio levels for waveform indicator
        self.audioManager.$audioLevels.sink { levels in
            WaveformIndicatorWindow.shared.updateAudioLevels(levels)
        }.store(in: &cancellables)
        
        // Observe status message updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateTranscriptionStatus),
            name: NSNotification.Name("TranscriptionStatusChanged"),
            object: nil
        )
        
        // Store the observer so it doesn't get deallocated
        self.notificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received hotkey notification")
            self?.toggleRecording()
        }
        // Observe cancel hotkey
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CancelHotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received cancel hotkey notification")
            self?.cancelRecording()
        }
        // Observe clipboard hotkey (record without auto-paste)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ClipboardHotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received clipboard hotkey notification")
            self?.toggleRecording(clipboardOnly: true)
        }
    }
    
    @objc private func updateTranscriptionStatus(_ notification: Notification) {
        if let status = notification.userInfo?["status"] as? String {
            DispatchQueue.main.async {
                self.transcriptionStatus = status
            }
        }
    }
    
    // Function to open the log file
    func openLogFile() {
        Logger.shared.openLogFile()
    }

    // Allow manual selection of an audio file to transcribe
    func selectFileForTranscription() {
        logInfo("RecordingCoordinator: Opening file picker for transcription")
        let panel = NSOpenPanel()
        panel.title = "Select Audio File"
        panel.prompt = "Transcribe"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie]

        let response = panel.runModal()
        guard response == .OK, let selectedURL = panel.url else { return }
        transcribeSelectedFile(selectedURL)
    }
    
    // Public method for UI to start/stop recording
    func toggleRecordingFromUI() {
        toggleRecording()
    }
    
    // Public method to cancel the current recording without transcribing
    func cancelRecording() {
        guard audioManager.isRecording else { return }
        logInfo("RecordingCoordinator: Cancelling recording at user request")
        mediaPlaybackManager.resumeIfWePaused()

        // Hide waveform indicator
        WaveformIndicatorWindow.shared.hide()
        
        if let url = audioManager.stopRecording() {
            recordingStore.markCancelled(url: url)
            logInfo("RecordingCoordinator: Retained cancelled recording at \(url.path)")
        }
        DispatchQueue.main.async {
            self.transcriptionManager.statusMessage = "Recording cancelled"
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionStatusChanged"),
                object: nil,
                userInfo: ["status": "Recording cancelled"]
            )
        }
    }
    
    private func toggleRecording(clipboardOnly: Bool = false) {
        logInfo("RecordingCoordinator: toggleRecording called, current state: \(audioManager.isRecording), clipboardOnly: \(clipboardOnly)")

        if audioManager.isRecording {
            logInfo("RecordingCoordinator: Stopping recording...")
            mediaPlaybackManager.resumeIfWePaused()

            if let recordingURL = audioManager.stopRecording() {
                logInfo("RecordingCoordinator: Got recording URL: \(recordingURL)")
                self.lastRecordingURL = recordingURL // Save for potential retry
                logInfo("Recording completed: \(recordingURL.lastPathComponent)")
                
                // Verify the file exists and has data
                if let fileSize = try? FileManager.default.attributesOfItem(atPath: recordingURL.path)[.size] as? Int64 {
                    logInfo("RecordingCoordinator: Recording file size: \(fileSize) bytes")
                    if fileSize > 0 {
                        // Switch to transcribing mode
                        WaveformIndicatorWindow.shared.showTranscribing()
                        transcribeAudio(recordingURL: recordingURL)
                    } else {
                        logError("RecordingCoordinator: Recording file is empty")
                        WaveformIndicatorWindow.shared.hide()
                        showRecordingError()
                    }
                } else {
                    logError("RecordingCoordinator: Could not get recording file size")
                    WaveformIndicatorWindow.shared.hide()
                    showRecordingError()
                }
            } else {
                // Don't show an error - this is likely an intentionally short or silent recording
                logInfo("RecordingCoordinator: Recording was too short or silent")
                WaveformIndicatorWindow.shared.hide()
            }
        } else {
            logInfo("RecordingCoordinator: Starting recording...")
            self.clipboardOnlyRecording = clipboardOnly

            // Pause media if enabled, then start recording
            mediaPlaybackManager.pauseIfPlaying { [weak self] in
                guard let self = self else { return }
                self.audioManager.startRecording()

                // Show waveform indicator with output mode context
                let autoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
                WaveformIndicatorWindow.shared.showWaveform(
                    clipboardOnly: clipboardOnly,
                    showOutputMode: autoPasteEnabled
                )
            }
        }
    }
    
    private func transcribeAudio(recordingURL: URL, forceClipboardOnly: Bool? = nil) {
        logInfo("Beginning transcription for file: \(recordingURL.lastPathComponent)")
        recordingStore.markTranscribing(
            url: recordingURL,
            model: transcriptionManager.transcriptionModel
        )
        
        // Use the new transcribeWithRetry method
        transcriptionManager.transcribeWithRetry(audioURL: recordingURL) { [weak self] text in
            guard let self = self else { return }
            
            if let text = text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                logInfo("RecordingCoordinator: Received transcription of \(trimmed.count) characters")
                self.recordingStore.markSucceeded(
                    url: recordingURL,
                    model: self.transcriptionManager.transcriptionModel,
                    transcript: trimmed
                )
                // Hide indicator on successful transcription
                WaveformIndicatorWindow.shared.hide()
                // Read the latest clipboardOnly state (user may have toggled via indicator bubble)
                let clipboardOnly = forceClipboardOnly ?? WaveformIndicatorWindow.shared.clipboardOnly
                self.transcriptionManager.handleTranscriptionOutput(trimmed, clipboardOnly: clipboardOnly)
            } else {
                logError("RecordingCoordinator: Transcription failed after retries")
                self.recordingStore.markFailed(
                    url: recordingURL,
                    model: self.transcriptionManager.transcriptionModel
                )
                // Hide indicator on failed transcription
                WaveformIndicatorWindow.shared.hide()
                DispatchQueue.main.async {
                    self.showTranscriptionErrorWithOptions(recordingURL: recordingURL)
                }
            }
        }
    }

    private func transcribeSelectedFile(_ fileURL: URL) {
        logInfo("RecordingCoordinator: Selected file for transcription: \(fileURL.path)")
        lastRecordingURL = fileURL

        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize > 0 {
            WaveformIndicatorWindow.shared.showTranscribing()
            transcribeAudio(recordingURL: fileURL)
        } else {
            logError("RecordingCoordinator: Selected file is empty or unreadable")
            showFileSelectionError()
        }
    }

    private func showFileSelectionError() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "File Error"
            alert.informativeText = "Unable to read the selected audio file. Please choose a different file."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    private func showRecordingError() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = "Failed to capture audio recording. Please try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    private func showTranscriptionErrorWithOptions(recordingURL: URL) {
        logInfo("Showing transcription error dialog with options")
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Transcription Error"
            alert.informativeText = "Failed to transcribe audio after multiple attempts. Please check your API key and internet connection."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Retry") // First button (return code: 1000)
            alert.addButton(withTitle: "Show in Finder") // Second button (return code: 1001)
            alert.addButton(withTitle: "View Logs") // Added third button
            alert.addButton(withTitle: "Cancel") // Fourth button (return code: 1003)
            
            let response = alert.runModal()
            
            switch response {
            case .alertFirstButtonReturn: // Retry
                logInfo("RecordingCoordinator: Retrying transcription")
                self.transcribeAudio(recordingURL: recordingURL)
                
            case .alertSecondButtonReturn: // Show in Finder
                logInfo("RecordingCoordinator: Showing in Finder: \(recordingURL)")
                NSWorkspace.shared.selectFile(recordingURL.path, inFileViewerRootedAtPath: "")
                
            case .alertThirdButtonReturn: // View Logs
                logInfo("RecordingCoordinator: Opening log file")
                self.openLogFile()
                
            default: // Cancel
                logInfo("RecordingCoordinator: Transcription error dismissed")
            }
        }
    }
    
    // Function to retry the last transcription from outside this class if needed
    func retryLastTranscription() {
        if let lastURL = lastRecordingURL, FileManager.default.fileExists(atPath: lastURL.path) {
            logInfo("Retrying last transcription attempt")
            transcribeAudio(recordingURL: lastURL, forceClipboardOnly: true)
        } else if let recording = recordingStore.recordings.first {
            retryRecording(recording)
        }
    }

    func retryRecording(_ recording: StoredRecording, chooseModel: Bool = false) {
        guard !transcriptionManager.isTranscribing else { return }
        let url = recordingStore.audioURL(for: recording)
        guard FileManager.default.fileExists(atPath: url.path) else {
            recordingStore.delete(recording)
            showFileSelectionError()
            return
        }

        let transcribe = { [weak self] in
            guard let self else { return }
            self.lastRecordingURL = url
            WaveformIndicatorWindow.shared.showTranscribing()
            self.transcribeAudio(recordingURL: url, forceClipboardOnly: true)
        }

        guard chooseModel else {
            transcribe()
            return
        }

        ModelSetupPanel.shared.show(
            model: transcriptionManager.transcriptionModel,
            openAIKey: transcriptionManager.currentOpenAIKey,
            groqKey: transcriptionManager.currentGroqAPIKey
        ) { [weak self] model, openAIKey, groqKey in
            guard let self else { return }
            self.transcriptionManager.setAPIKey(openAIKey)
            self.transcriptionManager.setGroqAPIKey(groqKey)
            self.transcriptionManager.setTranscriptionModel(model)
            transcribe()
        }
    }

    func revealRecording(_ recording: StoredRecording) {
        let url = recordingStore.audioURL(for: recording)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    func saveRecordingPermanently(_ recording: StoredRecording) {
        let sourceURL = recordingStore.audioURL(for: recording)
        let panel = NSSavePanel()
        panel.title = "Save Recording"
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Audio]
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
            recordingStore.markPermanent(recording)
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            recordingStore.markPermanent(recording)
            logInfo("RecordingCoordinator: Saved recording permanently to \(destinationURL.path)")
        } catch {
            logError("RecordingCoordinator: Failed to save recording permanently: \(error)")
            let alert = NSAlert()
            alert.messageText = "Could Not Save Recording"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func deleteRecording(_ recording: StoredRecording) {
        guard recording.status != .recording && recording.status != .transcribing else { return }
        recordingStore.delete(recording)
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("TranscriptionStatusChanged"), object: nil)
    }
} 
