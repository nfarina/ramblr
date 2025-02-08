import SwiftUI

class RecordingCoordinator: ObservableObject {
    private var audioManager: AudioManager
    private var transcriptionManager: TranscriptionManager
    private var notificationObserver: NSObjectProtocol?
    
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
                
                // Verify the file exists and has data
                if let fileSize = try? FileManager.default.attributesOfItem(atPath: recordingURL.path)[.size] as? Int64 {
                    print("RecordingCoordinator: Recording file size: \(fileSize) bytes")
                    if fileSize > 0 {
                        transcriptionManager.transcribe(audioURL: recordingURL) { [weak self] text in
                            guard let self = self else { return }
                            
                            if let text = text {
                                print("RecordingCoordinator: Received transcription: \(text)")
                                self.transcriptionManager.pasteText(text)
                            } else {
                                print("RecordingCoordinator: Transcription failed or returned nil")
                                DispatchQueue.main.async {
                                    self.showTranscriptionError()
                                }
                            }
                        }
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
    
    private func showTranscriptionError() {
        let alert = NSAlert()
        alert.messageText = "Transcription Error"
        alert.informativeText = "Failed to transcribe audio. Please check your API key and internet connection."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
} 