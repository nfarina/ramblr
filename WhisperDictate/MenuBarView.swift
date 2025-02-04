import SwiftUI

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
                if !transcriptionManager.hasAccessibilityPermission {
                    Text("Needs Accessibility Permission")
                        .foregroundColor(.red)
                } else if audioManager.isRecording {
                    Text("Recording...")
                        .foregroundColor(.red)
                } else {
                    Text("Ready")
                        .foregroundColor(.primary)
                }
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
            
            if !transcriptionManager.hasAccessibilityPermission {
                Text("⚠️ Accessibility permission required")
                    .font(.caption)
                    .foregroundColor(.red)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .padding(.bottom, 5)
            }
            
            Text("Press ⌘⌃R to start/stop recording")
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
