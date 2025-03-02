import SwiftUI

class RecordingCoordinator: ObservableObject {
    private var audioManager: AudioManager
    private var transcriptionManager: TranscriptionManager
    private var notificationObserver: NSObjectProtocol?
    private var lastRecordingURL: URL? // Store the last recording URL for retry
    
    init(audioManager: AudioManager, transcriptionManager: TranscriptionManager) {
        logInfo("RecordingCoordinator: Initializing")
        self.audioManager = audioManager
        self.transcriptionManager = transcriptionManager
        
        // Store the observer so it doesn't get deallocated
        self.notificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received hotkey notification")
            self?.toggleRecording()
        }
    }
    
    // Function to open the log file
    func openLogFile() {
        Logger.shared.openLogFile()
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
                        transcribeAudio(recordingURL: recordingURL)
                    } else {
                        logError("RecordingCoordinator: Recording file is empty")
                        showRecordingError()
                    }
                } else {
                    logError("RecordingCoordinator: Could not get recording file size")
                    showRecordingError()
                }
            } else {
                // Don't show an error - this is likely an intentionally short or silent recording
                logInfo("RecordingCoordinator: Recording was too short or silent")
            }
        } else {
            logInfo("RecordingCoordinator: Starting recording...")
            audioManager.startRecording()
        }
    }
    
    private func transcribeAudio(recordingURL: URL) {
        logInfo("Beginning transcription for file: \(recordingURL.lastPathComponent)")
        transcriptionManager.transcribe(audioURL: recordingURL) { [weak self] text in
            guard let self = self else { return }
            
            if let text = text {
                logInfo("RecordingCoordinator: Received transcription: \(text)")
                logInfo("Transcription successful: \(text.prefix(50))...")
                self.transcriptionManager.pasteText(text)
            } else {
                logError("RecordingCoordinator: Transcription failed or returned nil")
                DispatchQueue.main.async {
                    self.showTranscriptionErrorWithOptions(recordingURL: recordingURL)
                }
            }
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
        
        let alert = NSAlert()
        alert.messageText = "Transcription Error"
        alert.informativeText = "Failed to transcribe audio. Please check your API key and internet connection."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry") // First button (return code: 1000)
        alert.addButton(withTitle: "Show in Finder") // Second button (return code: 1001)
        alert.addButton(withTitle: "View Logs") // Added third button
        alert.addButton(withTitle: "Cancel") // Fourth button (return code: 1003)
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn: // Retry
            logInfo("RecordingCoordinator: Retrying transcription")
            transcribeAudio(recordingURL: recordingURL)
            
        case .alertSecondButtonReturn: // Show in Finder
            logInfo("RecordingCoordinator: Showing in Finder: \(recordingURL)")
            NSWorkspace.shared.selectFile(recordingURL.path, inFileViewerRootedAtPath: "")
            
        case .alertThirdButtonReturn: // View Logs
            logInfo("RecordingCoordinator: Opening log file")
            openLogFile()
            
        default: // Cancel
            logInfo("RecordingCoordinator: Transcription error dismissed")
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
    }
} 