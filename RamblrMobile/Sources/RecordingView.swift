import SwiftUI
import RamblrKit

struct RecordingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var recorder = AppModel.shared.recorder

    @State private var showSettings = false
    @State private var showHistory = false
    @State private var copiedFlash = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                statusText
                meter
                micButton
                actionRow
                Spacer()
                resultCard
            }
            .padding()
            .navigationTitle("Ramblr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHistory) { HistoryView() }
        }
    }

    // MARK: - Pieces

    private var statusText: some View {
        Group {
            switch model.phase {
            case .idle:
                Text(settings.isConfigured
                     ? "Tap to record"
                     : "Add an API key in Settings to begin")
                    .foregroundStyle(.secondary)
            case .recording:
                Text(timeString(recorder.elapsed))
                    .monospacedDigit()
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
            case .transcribing:
                Label("Transcribing…", systemImage: "waveform")
                    .foregroundStyle(.secondary)
            case .result:
                Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .error(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.headline)
        .frame(minHeight: 30)
        .animation(.default, value: model.phase)
    }

    private var meter: some View {
        HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { i in
                Capsule()
                    .fill(barColor(i))
                    .frame(width: 4, height: barHeight(i))
            }
        }
        .frame(height: 56)
        .opacity(model.phase == .recording ? 1 : 0.25)
        .animation(.easeOut(duration: 0.08), value: recorder.level)
    }

    private var micButton: some View {
        Button {
            Task { await model.toggle() }
        } label: {
            ZStack {
                Circle()
                    .fill(buttonColor.gradient)
                    .frame(width: 120, height: 120)
                    .shadow(color: buttonColor.opacity(0.4), radius: 16, y: 6)
                if model.phase == .transcribing {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(model.phase == .recording ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: model.phase)
        }
        .disabled(model.phase == .transcribing)
        .buttonStyle(.plain)
    }

    private var actionRow: some View {
        Group {
            if model.phase == .recording {
                Button(role: .destructive) { model.cancel() } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private var resultCard: some View {
        if case .result(let text) = model.phase {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)

                HStack {
                    Button {
                        model.copy(text)
                        flashCopied()
                    } label: {
                        Label(copiedFlash ? "Copied" : "Copy", systemImage: copiedFlash ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Button("Done") { model.reset() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private var buttonColor: Color {
        switch model.phase {
        case .recording: return .red
        case .error: return .orange
        default: return .accentColor
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        // Center bars react most; create a simple symmetric envelope.
        let distanceFromCenter = abs(Double(i) - 13.5) / 13.5
        let envelope = 1.0 - distanceFromCenter * 0.7
        let h = 8 + CGFloat(Double(recorder.level) * envelope) * 48
        return max(4, h)
    }

    private func barColor(_ i: Int) -> Color {
        model.phase == .recording ? .red.opacity(0.85) : .secondary.opacity(0.5)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func flashCopied() {
        copiedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFlash = false }
    }
}
