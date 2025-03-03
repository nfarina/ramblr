import SwiftUI

struct MenuBarView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var coordinator: RecordingCoordinator
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "OpenAIAPIKey") ?? ""
    
    init(audioManager: AudioManager, hotkeyManager: HotkeyManager, transcriptionManager: TranscriptionManager, coordinator: RecordingCoordinator) {
        self.audioManager = audioManager
        self.hotkeyManager = hotkeyManager
        self.transcriptionManager = transcriptionManager
        self.coordinator = coordinator
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
                } else if transcriptionManager.isTranscribing {
                    HStack(spacing: 4) {
                        if !transcriptionManager.statusMessage.isEmpty {
                            Text(transcriptionManager.statusMessage)
                                .foregroundColor(.yellow)
                        } else {
                            Text("Transcribing")
                                .foregroundColor(.yellow)
                        }
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                } else if !transcriptionManager.statusMessage.isEmpty {
                    Text(transcriptionManager.statusMessage)
                        .foregroundColor(.orange)
                } else {
                    Text("Ready")
                        .foregroundColor(.primary)
                }
            }
            
            if audioManager.networkStressLevel > 0 {
                HStack {
                    Image(systemName: "network")
                    Text("Network quality: reduced")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.top, 2)
            }
            
            Divider()
            
            VStack(alignment: .leading) {
                Text("OpenAI API Key:")
                SecureField("Enter API Key", text: $apiKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: apiKey) { oldValue, newValue in
                        transcriptionManager.setAPIKey(newValue)
                        logInfo("API Key updated")
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
                        logInfo("Opening Accessibility settings")
                    }
                }
                .padding(.bottom, 5)
            }
            
            Text("Press Option+D to start/stop recording")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            HStack {
                Button(action: {
                    logInfo("Viewing application logs")
                    Logger.shared.openLogFile()
                }) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("View Logs")
                    }
                }
                
                Spacer()
                
                Button(action: {
                    logInfo("User initiated app quit")
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                }
            }
        }
        .padding()
        .frame(width: 250)
    }
}
