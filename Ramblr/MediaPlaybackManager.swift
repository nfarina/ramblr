import Foundation
import AppKit

class MediaPlaybackManager: ObservableObject {

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "MediaPauseOnRecordEnabled")
            logInfo("MediaPlaybackManager: Enabled set to \(isEnabled)")
        }
    }

    private var didWePauseMedia = false
    private var helperPath: String?

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "MediaPauseOnRecordEnabled")
        self.helperPath = findHelper()
        if let path = helperPath {
            logInfo("MediaPlaybackManager: Found media-helper at \(path)")
        } else {
            logWarning("MediaPlaybackManager: media-helper not found in app bundle")
        }
    }

    // MARK: - Locate bundled helper

    private func findHelper() -> String? {
        // Look in the app bundle's Resources directory
        if let path = Bundle.main.path(forResource: "media-helper", ofType: nil) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Run helper commands

    private func runHelper(_ arguments: [String], timeout: TimeInterval = 5.0) -> String? {
        guard let path = helperPath else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            logError("MediaPlaybackManager: Failed to run media-helper: \(error)")
            return nil
        }

        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isMediaPlaying() -> Bool {
        guard let output = runHelper(["get-state"]) else { return false }
        logInfo("MediaPlaybackManager: get-state = \(output)")
        return output == "playing"
    }

    // MARK: - Pause / Resume

    func pauseIfPlaying(completion: @escaping () -> Void) {
        guard isEnabled else { completion(); return }

        guard helperPath != nil else {
            logWarning("MediaPlaybackManager: media-helper not available, skipping")
            completion()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion(); return }
            let playing = self.isMediaPlaying()

            if playing {
                logInfo("MediaPlaybackManager: Media is playing, pausing")
                let result = self.runHelper(["pause"])
                logInfo("MediaPlaybackManager: Pause result: \(result ?? "nil")")
                DispatchQueue.main.async {
                    self.didWePauseMedia = true
                    completion()
                }
            } else {
                logInfo("MediaPlaybackManager: Nothing playing, skipping pause")
                DispatchQueue.main.async {
                    self.didWePauseMedia = false
                    completion()
                }
            }
        }
    }

    func resumeIfWePaused() {
        guard isEnabled, didWePauseMedia else { return }
        didWePauseMedia = false

        guard helperPath != nil else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Check if still paused (user may have manually resumed during recording)
            let playing = self.isMediaPlaying()
            if !playing {
                logInfo("MediaPlaybackManager: Resuming playback")
                let result = self.runHelper(["play"])
                logInfo("MediaPlaybackManager: Play result: \(result ?? "nil")")
            } else {
                logInfo("MediaPlaybackManager: Media already playing, skipping resume")
            }
        }
    }
}
