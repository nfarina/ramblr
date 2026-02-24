import SwiftUI
import Combine
import AppKit

class RecordingCoordinator: ObservableObject {
    private var audioManager: AudioManager
    private var transcriptionManager: TranscriptionManager
    private var notificationObserver: NSObjectProtocol?
    private var lastRecordingURL: URL? // Store the last recording URL for retry
    private var cancellables = Set<AnyCancellable>()
    
    @Published var transcriptionStatus: String = ""
    
    init(audioManager: AudioManager, transcriptionManager: TranscriptionManager) {
        logInfo("RecordingCoordinator: Initializing")
        self.audioManager = audioManager
        self.transcriptionManager = transcriptionManager

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
        panel.allowedFileTypes = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "mp4", "mkv", "webm", "qta"]

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
        
        // Hide waveform indicator
        WaveformIndicatorWindow.shared.hide()
        
        if let url = audioManager.stopRecording() {
            // Move the file next to the default recording file as cancelled.wav
            let dir = url.deletingLastPathComponent()
            let destURL = dir.appendingPathComponent("cancelled.wav")
            // Remove existing cancelled.wav if present
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.moveItem(at: url, to: destURL)
                logInfo("RecordingCoordinator: Saved cancelled recording to \(destURL.path)")
            } catch {
                logError("RecordingCoordinator: Failed to move cancelled recording: \(error)")
            }
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
    
    private func toggleRecording() {
        logInfo("RecordingCoordinator: toggleRecording called, current state: \(audioManager.isRecording)")
        
        if audioManager.isRecording {
            logInfo("RecordingCoordinator: Stopping recording...")
            
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
            audioManager.startRecording()
            
            // Show waveform indicator
            WaveformIndicatorWindow.shared.showWaveform()
        }
    }
    
    private func transcribeAudio(recordingURL: URL) {
        logInfo("Beginning transcription for file: \(recordingURL.lastPathComponent)")
        
        // Use the new transcribeWithRetry method
        transcriptionManager.transcribeWithRetry(audioURL: recordingURL) { [weak self] text in
            guard let self = self else { return }
            
            if let text = text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                logInfo("RecordingCoordinator: Received transcription: \(trimmed)")
                logInfo("Transcription successful: \(trimmed.prefix(50))...")
                // Hide indicator on successful transcription
                WaveformIndicatorWindow.shared.hide()
                self.transcriptionManager.handleTranscriptionOutput(trimmed)
            } else {
                logError("RecordingCoordinator: Transcription failed after retries")
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
        if let lastURL = lastRecordingURL {
            logInfo("Retrying last transcription attempt")
            transcribeAudio(recordingURL: lastURL)
        }
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("TranscriptionStatusChanged"), object: nil)
    }
} 
