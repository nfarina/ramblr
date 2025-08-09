import SwiftUI

struct MenuBarView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var coordinator: RecordingCoordinator
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "OpenAIAPIKey") ?? ""
    @State private var autoPasteEnabled: Bool = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
    
    init(audioManager: AudioManager, hotkeyManager: HotkeyManager, transcriptionManager: TranscriptionManager, coordinator: RecordingCoordinator) {
        self.audioManager = audioManager
        self.hotkeyManager = hotkeyManager
        self.transcriptionManager = transcriptionManager
        self.coordinator = coordinator
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ramblr")
                .font(.headline)
                .padding(.bottom, 5)
            
            HStack {
                Text("Status:")
                if autoPasteEnabled && !transcriptionManager.hasAccessibilityPermission {
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

//                Toggle(isOn: $autoPasteEnabled) {
//                    VStack(alignment: .leading, spacing: 2) {
//                        Text("Auto-paste into active app")
//                        Text("Off: copy to clipboard + notify")
//                            .font(.caption)
//                            .foregroundColor(.secondary)
//                    }
//                }
//                .onChange(of: autoPasteEnabled) { _, newValue in
//                    UserDefaults.standard.set(newValue, forKey: "AutoPasteEnabled")
//                    logInfo("AutoPasteEnabled set to \(newValue)")
//                    if newValue {
//                        transcriptionManager.checkAccessibilityPermission(shouldPrompt: true)
//                    }
//                }
            }
            .padding(.vertical, 5)
            
            if autoPasteEnabled && !transcriptionManager.hasAccessibilityPermission {
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
            
            // Start/Stop controls
            HStack(spacing: 8) {
                Button(action: {
                    coordinator.toggleRecordingFromUI()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: audioManager.isRecording ? "stop.circle" : "record.circle")
                        Text(audioManager.isRecording ? "Stop Recording" : "Start Recording")
                    }
                }
                .keyboardShortcut(.defaultAction)

                if audioManager.isRecording {
                    Button(action: {
                        coordinator.cancelRecording()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle")
                            Text("Cancel")
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text("Press Option+D to start/stop recording")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            // History section
            if !transcriptionManager.history.isEmpty {
                Text("History")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(transcriptionManager.history.enumerated()), id: \.offset) { _, item in
                        Button(action: {
                            transcriptionManager.copyFromHistory(item)
                        }) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "doc.on.doc")
                                Text(item)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

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
                
                if !transcriptionManager.history.isEmpty {
                    Button(action: {
                        transcriptionManager.clearHistory()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear History")
                        }
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
        .frame(width: 320)
    }
}
