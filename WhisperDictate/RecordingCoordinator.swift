import SwiftUI

class RecordingCoordinator: ObservableObject {
    private var audioManager: AudioManager
    private var transcriptionManager: TranscriptionManager
    private var notificationObserver: NSObjectProtocol?
    private var lastRecordingURL: URL? // Store the last recording URL for retry
    
    init(audioManager: AudioManager, transcriptionManager: TranscriptionManager) {
        print("RecordingCoordinator: Initializing")
        self.audioManager = audioManager
        self.transcriptionManager = transcriptionManager
        
        // Store the observer so it doesn't get deallocated
        self.notificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("RecordingCoordinator: Received hotkey notification")
            self?.toggleRecording()
        }
    }
    
    private func toggleRecording() {
        print("RecordingCoordinator: toggleRecording called, current state: \(audioManager.isRecording)")
        
        if audioManager.isRecording {
            print("RecordingCoordinator: Stopping recording...")
            if let recordingURL = audioManager.stopRecording() {
                print("RecordingCoordinator: Got recording URL: \(recordingURL)")
                self.lastRecordingURL = recordingURL // Save for potential retry
                
                // Verify the file exists and has data
                if let fileSize = try? FileManager.default.attributesOfItem(atPath: recordingURL.path)[.size] as? Int64 {
                    print("RecordingCoordinator: Recording file size: \(fileSize) bytes")
                    if fileSize > 0 {
                        transcribeAudio(recordingURL: recordingURL)
                    } else {
                        print("RecordingCoordinator: Recording file is empty")
                        showRecordingError()
                    }
                } else {
                    print("RecordingCoordinator: Could not get recording file size")
                    showRecordingError()
                }
            } else {
                // Don't show an error - this is likely an intentionally short or silent recording
                print("RecordingCoordinator: Recording was too short or silent")
            }
        } else {
            print("RecordingCoordinator: Starting recording...")
            audioManager.startRecording()
        }
    }
    
    private func transcribeAudio(recordingURL: URL) {
        transcriptionManager.transcribe(audioURL: recordingURL) { [weak self] text in
            guard let self = self else { return }
            
            if let text = text {
                print("RecordingCoordinator: Received transcription: \(text)")
                self.transcriptionManager.pasteText(text)
            } else {
                print("RecordingCoordinator: Transcription failed or returned nil")
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
        let alert = NSAlert()
        alert.messageText = "Transcription Error"
        alert.informativeText = "Failed to transcribe audio. Please check your API key and internet connection."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry") // First button (return code: 1000)
        alert.addButton(withTitle: "Show in Finder") // Second button (return code: 1001)
        alert.addButton(withTitle: "Cancel") // Third button (return code: 1002)
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn: // Retry
            print("RecordingCoordinator: Retrying transcription")
            transcribeAudio(recordingURL: recordingURL)
            
        case .alertSecondButtonReturn: // Show in Finder
            print("RecordingCoordinator: Showing in Finder: \(recordingURL)")
            NSWorkspace.shared.selectFile(recordingURL.path, inFileViewerRootedAtPath: "")
            
        default: // Cancel
            print("RecordingCoordinator: Transcription error dismissed")
        }
    }
    
    // Function to retry the last transcription from outside this class if needed
    func retryLastTranscription() {
        if let lastURL = lastRecordingURL {
            transcribeAudio(recordingURL: lastURL)
        }
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
} 