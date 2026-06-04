import SwiftUI
import RamblrKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Picker("Transcription model", selection: modelBinding) {
                        ForEach(TranscriptionModel.presets, id: \.identifier) { model in
                            Text(model.displayName).tag(model.identifier)
                        }
                    }
                }

                Section {
                    SecureField("Groq API key", text: $settings.groqKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Groq")
                } footer: {
                    Text("Get a key at console.groq.com — Whisper large v3 is fast and free-tier friendly.")
                }

                Section {
                    SecureField("OpenAI API key", text: $settings.openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("OpenAI")
                } footer: {
                    Text("Get a key at platform.openai.com.")
                }

                Section {
                    Label("Tip: assign \"Start Ramblr Recording\" to your Action Button via Settings → Action Button → Shortcut.",
                          systemImage: "bolt.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.model.identifier },
            set: { settings.model = TranscriptionModel(identifier: $0) }
        )
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView("No transcriptions yet",
                                           systemImage: "clock",
                                           description: Text("Your recent transcriptions will appear here."))
                } else {
                    List {
                        ForEach(model.history, id: \.self) { text in
                            Button {
                                model.copy(text)
                            } label: {
                                Text(text)
                                    .lineLimit(4)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.history.isEmpty {
                        Button("Clear", role: .destructive) { model.clearHistory() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
