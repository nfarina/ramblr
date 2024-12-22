import SwiftUI

class RecordingCoordinator: ObservableObject {
    private var audioManager: AudioManager
    private var transcriptionManager: TranscriptionManager
    
    init(audioManager: AudioManager, transcriptionManager: TranscriptionManager) {
        self.audioManager = audioManager
        self.transcriptionManager = transcriptionManager
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("HotkeyPressed"),
                                             object: nil,
                                             queue: .main) { [weak self] _ in
            self?.toggleRecording()
        }
    }
    
    private func toggleRecording() {
        if audioManager.isRecording {
            if let recordingURL = audioManager.stopRecording() {
                transcriptionManager.transcribe(audioURL: recordingURL) { text in
                    if let text = text {
                        self.transcriptionManager.pasteText(text)
                    }
                }
            }
        } else {
            audioManager.startRecording()
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var transcriptionManager: TranscriptionManager
    @StateObject private var coordinator: RecordingCoordinator
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "OpenAIAPIKey") ?? ""
    
    init(audioManager: AudioManager, hotkeyManager: HotkeyManager, transcriptionManager: TranscriptionManager) {
        self.audioManager = audioManager
        self.hotkeyManager = hotkeyManager
        self.transcriptionManager = transcriptionManager
        self._coordinator = StateObject(wrappedValue: RecordingCoordinator(audioManager: audioManager, transcriptionManager: transcriptionManager))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WhisperDictate")
                .font(.headline)
                .padding(.bottom, 5)
            
            HStack {
                Text("Status:")
                Text(audioManager.isRecording ? "Recording..." : "Ready")
                    .foregroundColor(audioManager.isRecording ? .red : .primary)
            }
            
            Divider()
            
            VStack(alignment: .leading) {
                Text("OpenAI API Key:")
                SecureField("Enter API Key", text: $apiKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: apiKey) { newValue in
                        transcriptionManager.setAPIKey(newValue)
                    }
            }
            .padding(.vertical, 5)
            
            Text("Press ⌘⇧R to start/stop recording")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("Quit")
            }
        }
        .padding()
        .frame(width: 250)
    }
}
