import Foundation
import AVFoundation
import Combine

/// Records microphone audio to a compact AAC/m4a file suitable for Whisper.
///
/// Whisper internally resamples to 16 kHz mono, so we record at that rate to
/// keep uploads small and transcription fast.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    /// Normalized 0...1 input level for a simple waveform/meter.
    @Published private(set) var level: Float = 0
    /// Elapsed recording time in seconds.
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startDate: Date?

    /// Where the most recent recording was written.
    private(set) var currentURL: URL?

    // MARK: - Permission

    /// Request microphone permission, returning whether it was granted.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    var permissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    // MARK: - Recording

    func start() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramblr-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw NSError(domain: "Ramblr", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start recording."])
        }

        self.recorder = recorder
        self.currentURL = url
        self.isRecording = true
        self.startDate = Date()
        self.elapsed = 0
        startMetering()
    }

    /// Stop recording and return the file URL, or nil if nothing was captured.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return currentURL }
        recorder?.stop()
        stopMetering()
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return currentURL
    }

    func discard() {
        _ = stop()
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        currentURL = nil
    }

    // MARK: - Metering

    private func startMetering() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeter() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        // Convert dBFS (-160...0) to a perceptual 0...1 level.
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, (power + 50) / 50)
        level = min(1, normalized)
        if let startDate { elapsed = Date().timeIntervalSince(startDate) }
    }
}
