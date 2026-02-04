import SwiftUI
import Carbon

struct MenuBarView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var coordinator: RecordingCoordinator
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "OpenAIAPIKey") ?? ""
    @State private var groqApiKey: String = UserDefaults.standard.string(forKey: "GroqAPIKey") ?? ""
    @State private var autoPasteEnabled: Bool = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? true
    @State private var showHotkeyChangePopover: Bool = false
    @State private var showCancelHotkeyChangePopover: Bool = false
    
    
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
                .padding(.top, 2)
                .padding(.bottom, 2)
            
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
                        .opacity(0.6)
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
            
            Divider().padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 8) {
                // OpenAI key row
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("OpenAI API Key:")
                    Spacer()
                    Button(apiKey.isEmpty ? "Set" : "Edit") {
                        KeyEntryPanel.shared.show(title: "OpenAI API Key", initialValue: apiKey) { newValue in
                            apiKey = newValue
                            transcriptionManager.setAPIKey(newValue)
                            logInfo("OpenAI API Key updated")
                        }
                    }
                }
                // Groq key row
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Groq API Key:")
                    Spacer()
                    Button(groqApiKey.isEmpty ? "Set" : "Edit") {
                        KeyEntryPanel.shared.show(title: "Groq API Key", initialValue: groqApiKey) { newValue in
                            groqApiKey = newValue
                            transcriptionManager.setGroqAPIKey(newValue)
                            logInfo("Groq API Key updated")
                        }
                    }
                }
                Text("Groq recommended — much faster.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, -4)
                
                Divider().padding(.top, 5).padding(.bottom, 8)

                // Transcription model selector (now dropdown for more options)
                Picker("Model:", selection: Binding(
                    get: { transcriptionManager.transcriptionModel },
                    set: { newValue in
                        transcriptionManager.setTranscriptionModel(newValue)
                        // Force view state to refresh binding immediately
                        // by triggering a trivial state change
                        self.autoPasteEnabled = self.autoPasteEnabled
                    }
                )) {
                    // Provider-prefixed unique tags
                    Text("Whisper (OpenAI)").tag("openai:whisper-1")
                    Text("Whisper (Groq)").tag("groq:whisper-large-v3")
                    Text("GPT-4o").tag("openai:gpt-4o-transcribe")
                    Text("GPT-4o mini").tag("openai:gpt-4o-mini-transcribe")
                }
                .pickerStyle(.menu)

                Divider().padding(.top, 6)

                Toggle(isOn: $autoPasteEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-paste into active app")
                        Text("Off: copy to clipboard + notify")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: autoPasteEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "AutoPasteEnabled")
                    logInfo("AutoPasteEnabled set to \(newValue)")
                    if newValue {
                        transcriptionManager.checkAccessibilityPermission(shouldPrompt: true)
                    }
                }
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
            VStack(alignment: .leading, spacing: 6) {
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

                Button(action: {
                    coordinator.selectFileForTranscription()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                        Text("Transcribe File...")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
                .disabled(audioManager.isRecording || transcriptionManager.isTranscribing)
            }
            // Hotkey hints and change links
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Press")
                    Text(hotkeyManager.displayString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("to start/stop recording.")
                    Button(action: { showHotkeyChangePopover = true }) {
                        Text("Change").underline()
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showHotkeyChangePopover, arrowEdge: .top) {
                        VStack(spacing: 6) {
                            Text("Press desired shortcut")
                                .font(.headline)
                            Text("Include modifiers like ⌘ ⌥ ⌃ ⇧")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            KeyCaptureRepresentable(
                                onCaptured: { keyCode, flags in
                                    let carbonMods = HotkeyManager.carbonFlags(from: flags)
                                    hotkeyManager.updateHotkey(keyCode: UInt32(keyCode), modifiers: carbonMods)
                                    showHotkeyChangePopover = false
                                },
                                onCancel: { showHotkeyChangePopover = false }
                            )
                            .frame(width: 200, height: 0)
                        }
                        .padding(8)
                        .padding(.top, 6)
                    }
                }
                HStack(spacing: 4) {
                    Text("Press")
                    Text(hotkeyManager.cancelDisplayString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("to cancel recording.")
                    Button(action: { showCancelHotkeyChangePopover = true }) {
                        Text("Change").underline()
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showCancelHotkeyChangePopover, arrowEdge: .top) {
                        VStack(spacing: 6) {
                            Text("Press desired shortcut")
                                .font(.headline)
                            Text("Include modifiers like ⌘ ⌥ ⌃ ⇧")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            KeyCaptureRepresentable(
                                onCaptured: { keyCode, flags in
                                    let carbonMods = HotkeyManager.carbonFlags(from: flags)
                                    hotkeyManager.updateCancelHotkey(keyCode: UInt32(keyCode), modifiers: carbonMods)
                                    showCancelHotkeyChangePopover = false
                                },
                                onCancel: { showCancelHotkeyChangePopover = false }
                            )
                            .frame(width: 200, height: 0)
                        }
                        .padding(8)
                        .padding(.top, 6)
                    }
                }
            }
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
        .onAppear {
            // Refresh accessibility status whenever the menu opens
            transcriptionManager.checkAccessibilityPermission(shouldPrompt: false)
            hotkeyManager.checkPermissions()
        }
        // Detached panel used instead of sheets for key entry (prevents menu dismissal)
    }
}

// MARK: - Key Edit Sheet

// Old in-menu sheet removed in favor of detached NSPanel (KeyEntryPanel)

// NSView-based key capture to reliably receive keyDown with modifiers
private struct KeyCaptureRepresentable: NSViewRepresentable {
    let onCaptured: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void
    
    func makeNSView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.onCaptured = onCaptured
        v.onCancel = onCancel
        return v
    }
    
    func updateNSView(_ nsView: KeyCaptureView, context: Context) {}
}

private final class KeyCaptureView: NSView {
    var onCaptured: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
    
    override func keyDown(with event: NSEvent) {
        // Capture the keycode and current modifier flags
        onCaptured?(event.keyCode, event.modifierFlags)
    }
    
    override func flagsChanged(with event: NSEvent) {
        // Ignore standalone modifier changes
    }
    
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
