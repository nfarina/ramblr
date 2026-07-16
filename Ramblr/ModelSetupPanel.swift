import SwiftUI
import AppKit

final class ModelSetupPanel {
    static let shared = ModelSetupPanel()
    private var window: NSPanel?

    func show(
        model: String,
        openAIKey: String,
        groqKey: String,
        onSave: @escaping (String, String, String) -> Void
    ) {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = ModelSetupView(
            initialModel: model,
            initialOpenAIKey: openAIKey,
            initialGroqKey: groqKey
        ) { model, openAIKey, groqKey in
            onSave(model, openAIKey, groqKey)
            self.close()
        } onCancel: {
            self.close()
        }

        let hosting = NSHostingController(rootView: content)
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Transcription Setup"
        panel.styleMask = [.titled, .closable, .utilityWindow]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.setContentSize(NSSize(width: 440, height: 240))
        panel.center()

        self.window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct ModelSetupView: View {
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void
    @State private var model: String
    @State private var openAIKey: String
    @State private var groqKey: String

    init(
        initialModel: String,
        initialOpenAIKey: String,
        initialGroqKey: String,
        onSave: @escaping (String, String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _model = State(initialValue: initialModel)
        _openAIKey = State(initialValue: initialOpenAIKey)
        _groqKey = State(initialValue: initialGroqKey)
    }

    private var needsOpenAI: Bool {
        model.hasPrefix("openai:")
    }

    private var needsGroq: Bool {
        model.hasPrefix("groq:")
    }

    private var requiredKeyMissing: Bool {
        if needsGroq { return groqKey.isEmpty }
        return openAIKey.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription Setup").font(.headline)

            HStack {
                Picker("Model:", selection: $model) {
                    Text("Whisper (OpenAI)").tag("openai:whisper-1")
                    Text("Whisper (Groq)").tag("groq:whisper-large-v3")
                    Text("GPT-4o").tag("openai:gpt-4o-transcribe")
                    Text("GPT-4o mini").tag("openai:gpt-4o-mini-transcribe")
                }
                .pickerStyle(.menu)
                Text("Groq recommended — much faster.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if needsOpenAI {
                HStack {
                    Text("OpenAI API Key:")
                    SecureField("sk-...", text: $openAIKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            openAIKey = s
                        }
                    }
                }
            }

            if needsGroq {
                HStack {
                    Text("Groq API Key:")
                    SecureField("gsk_...", text: $groqKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            groqKey = s
                        }
                    }
                }
            }

            if requiredKeyMissing {
                Text("API key required for the selected model.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") {
                    onSave(model, openAIKey, groqKey)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 400)
    }
}
