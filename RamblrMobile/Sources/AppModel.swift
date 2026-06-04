import Foundation
import SwiftUI
import UIKit
import Combine
import RamblrKit

/// Central coordinator for the recording → transcription → clipboard flow.
///
/// A singleton so the App Intent (Action Button) can reach it without going
/// through the SwiftUI environment.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case result(String)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var history: [String] = []
    /// Set by the App Intent so the UI auto-starts recording once it appears.
    @Published var pendingAutoStart = false

    let settings = AppSettings()
    let recorder = AudioRecorder()
    private let service: TranscriptionService

    private let historyKey = "TranscriptionHistory"
    private let maxHistory = 50

    private init() {
        service = TranscriptionService(log: { print("[RamblrKit] \($0)") })
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    // MARK: - Intent entry point

    /// Called by the Action Button intent. Flags an auto-start; the UI performs
    /// it once the scene is active so permission prompts present correctly.
    func requestAutoStart() {
        pendingAutoStart = true
    }

    /// Perform a queued auto-start, if any.
    func performPendingAutoStartIfNeeded() async {
        guard pendingAutoStart else { return }
        pendingAutoStart = false
        if case .recording = phase { return }
        await startRecording()
    }

    // MARK: - Recording flow

    var isBusy: Bool {
        switch phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    func toggle() async {
        switch phase {
        case .recording:
            await stopAndTranscribe()
        case .transcribing:
            break
        default:
            await startRecording()
        }
    }

    func startRecording() async {
        guard settings.isConfigured else {
            phase = .error("Add your \(settings.model.provider.displayName) API key in Settings first.")
            return
        }

        var granted = recorder.permissionGranted
        if !granted { granted = await recorder.requestPermission() }
        guard granted else {
            phase = .error("Microphone access is off. Enable it in Settings → Ramblr.")
            return
        }

        do {
            try recorder.start()
            phase = .recording
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func cancel() {
        recorder.discard()
        phase = .idle
    }

    func stopAndTranscribe() async {
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        phase = .transcribing
        do {
            let text = try await service.transcribeWithRetry(
                audioURL: url,
                model: settings.model,
                apiKey: settings.activeKey
            )
            try? FileManager.default.removeItem(at: url)

            guard !text.isEmpty else {
                phase = .error("No speech detected.")
                return
            }
            UIPasteboard.general.string = text
            addToHistory(text)
            phase = .result(text)
        } catch let error as TranscriptionError {
            phase = .error(error.description)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func reset() {
        phase = .idle
    }

    // MARK: - History

    func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func addToHistory(_ text: String) {
        history.insert(text, at: 0)
        if history.count > maxHistory { history = Array(history.prefix(maxHistory)) }
        UserDefaults.standard.set(history, forKey: historyKey)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.set(history, forKey: historyKey)
    }
}
