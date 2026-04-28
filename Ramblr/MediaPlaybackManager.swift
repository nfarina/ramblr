import Foundation
import AppKit

class MediaPlaybackManager: ObservableObject {

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "MediaPauseOnRecordEnabled")
            logInfo("MediaPlaybackManager: Enabled set to \(isEnabled)")
        }
    }

    @Published private(set) var availabilityError: String?

    private var didWePauseMedia = false
    private var didShowUnavailableAlert = false
    private var helperPath: String?
    private var adapterPath: String?

    private enum PlaybackState {
        case playing
        case stopped
        case unavailable(String)
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "MediaPauseOnRecordEnabled")
        refreshAvailability()
    }

    // MARK: - Locate bundled helper

    private func refreshAvailability() {
        helperPath = nil
        adapterPath = nil
        availabilityError = nil

        guard let path = Bundle.main.path(forResource: "media-helper", ofType: nil) else {
            setUnavailable("media-helper is missing from the app bundle. Rebuild Ramblr after installing media-control.")
            return
        }

        guard FileManager.default.isExecutableFile(atPath: path) else {
            setUnavailable("media-helper is bundled but is not executable. Rebuild Ramblr.")
            return
        }

        let resourcesURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        let adapterURL = resourcesURL.appendingPathComponent("MediaRemoteAdapter.dylib")
        guard FileManager.default.fileExists(atPath: adapterURL.path) else {
            setUnavailable("MediaRemoteAdapter.dylib is missing from the app bundle. Install media-control and rebuild Ramblr.")
            return
        }

        helperPath = path
        adapterPath = adapterURL.path
        logInfo("MediaPlaybackManager: Found media-helper at \(path)")
        logInfo("MediaPlaybackManager: Found MediaRemoteAdapter.dylib at \(adapterURL.path)")
    }

    private func setUnavailable(_ message: String) {
        logError("MediaPlaybackManager: \(message)")

        if Thread.isMainThread {
            availabilityError = message
        } else {
            DispatchQueue.main.async {
                self.availabilityError = message
            }
        }
    }

    private func reportUnavailable(_ message: String? = nil, completion: @escaping () -> Void) {
        let message = message ?? availabilityError ?? "Pause media is unavailable because the media helper is not ready."
        logError("MediaPlaybackManager: \(message)")

        let showAlertAndContinue = {
            self.availabilityError = message

            if !self.didShowUnavailableAlert {
                self.didShowUnavailableAlert = true

                let alert = NSAlert()
                alert.messageText = "Pause Media Unavailable"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }

            completion()
        }

        if Thread.isMainThread {
            showAlertAndContinue()
        } else {
            DispatchQueue.main.async(execute: showAlertAndContinue)
        }
    }

    // MARK: - Run helper commands

    private func runHelper(_ arguments: [String]) -> String? {
        guard let path = helperPath else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            logError("MediaPlaybackManager: Failed to run media-helper: \(error)")
            return nil
        }

        proc.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if proc.terminationStatus != 0 {
            let detail = stderr.isEmpty ? stdout : stderr
            logError("MediaPlaybackManager: media-helper \(arguments.joined(separator: " ")) failed with exit code \(proc.terminationStatus): \(detail)")
            return nil
        }

        if !stderr.isEmpty {
            logWarning("MediaPlaybackManager: media-helper \(arguments.joined(separator: " ")) wrote stderr: \(stderr)")
        }

        return stdout
    }

    private func playbackState() -> PlaybackState {
        guard let output = runHelper(["get-state"]) else {
            logError("MediaPlaybackManager: Unable to determine media playback state")
            return .unavailable("Pause media helper failed. Check the Ramblr log for details.")
        }

        logInfo("MediaPlaybackManager: get-state = \(output)")

        switch output {
        case "playing":
            return .playing
        case "stopped":
            return .stopped
        default:
            let detail = output.isEmpty ? "<empty>" : output
            logError("MediaPlaybackManager: Unexpected media-helper get-state output: \(detail)")
            return .unavailable("Pause media helper returned an unexpected playback state. Check the Ramblr log for details.")
        }
    }

    // MARK: - Pause / Resume

    func pauseIfPlaying(completion: @escaping () -> Void) {
        guard isEnabled else { completion(); return }

        guard availabilityError == nil, helperPath != nil, adapterPath != nil else {
            reportUnavailable(completion: completion)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion(); return }

            switch self.playbackState() {
            case .playing:
                logInfo("MediaPlaybackManager: Media is playing, pausing")
                let result = self.runHelper(["pause"])
                logInfo("MediaPlaybackManager: Pause result: \(result ?? "nil")")
                DispatchQueue.main.async {
                    self.didWePauseMedia = true
                    completion()
                }

            case .stopped:
                logInfo("MediaPlaybackManager: Nothing playing, skipping pause")
                DispatchQueue.main.async {
                    self.didWePauseMedia = false
                    completion()
                }

            case .unavailable(let message):
                DispatchQueue.main.async {
                    self.didWePauseMedia = false
                    self.reportUnavailable(message, completion: completion)
                }
            }
        }
    }

    func resumeIfWePaused() {
        guard isEnabled, didWePauseMedia else { return }
        didWePauseMedia = false

        guard availabilityError == nil, helperPath != nil, adapterPath != nil else {
            logError("MediaPlaybackManager: Cannot resume media because pause media support is unavailable")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Check if still paused (user may have manually resumed during recording)
            switch self.playbackState() {
            case .stopped:
                logInfo("MediaPlaybackManager: Resuming playback")
                let result = self.runHelper(["play"])
                logInfo("MediaPlaybackManager: Play result: \(result ?? "nil")")

            case .playing:
                logInfo("MediaPlaybackManager: Media already playing, skipping resume")

            case .unavailable(let message):
                self.setUnavailable(message)
            }
        }
    }
}
