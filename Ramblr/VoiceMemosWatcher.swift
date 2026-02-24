import Foundation
import AppKit

class VoiceMemosWatcher: ObservableObject {

    // MARK: - Published State

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            if isEnabled {
                startWatching()
            } else {
                stopWatching()
            }
        }
    }
    @Published var isProcessing: Bool = false

    // MARK: - Constants

    private let enabledKey = "VoiceMemosWatcherEnabled"
    private let processedFilesKey = "VoiceMemosProcessedFiles"
    private let initializedKey = "VoiceMemosInitialized"
    private let watchedExtensions: Set<String> = ["m4a", "qta"]
    private let fileSizeStabilityDelay: TimeInterval = 2.0
    private let retryDelay: TimeInterval = 5.0

    // MARK: - Dependencies

    private weak var transcriptionManager: TranscriptionManager?

    // MARK: - Internal State

    private var processedFileNames: Set<String> = []
    private var pendingFiles: [URL] = []
    private var directoryFileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.nfarina.Ramblr.voiceMemos", qos: .utility)

    // MARK: - Directory Path

    private var voiceMemosDirectoryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            return dir
        }
        return nil
    }

    // MARK: - Init

    init(transcriptionManager: TranscriptionManager) {
        self.transcriptionManager = transcriptionManager
        loadProcessedFiles()

        let wasEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        if wasEnabled {
            // Set directly to trigger didSet → startWatching
            isEnabled = true
        }
    }

    deinit {
        stopWatching()
    }

    // MARK: - Watching

    private func startWatching() {
        // Stop any existing watcher first
        stopWatching()

        guard let dirURL = voiceMemosDirectoryURL else {
            logWarning("VoiceMemosWatcher: Voice Memos directory not found. Watcher will not start.")
            showNoVoiceMemosAlert()
            revertEnabled()
            return
        }

        // Check we can actually read the directory (requires Full Disk Access)
        if !hasDirectoryAccess(dirURL) {
            logWarning("VoiceMemosWatcher: No permission to read Voice Memos directory")
            showFullDiskAccessAlert()
            revertEnabled()
            return
        }

        // On first enable, snapshot existing files so we only transcribe future recordings
        if processedFileNames.isEmpty && !UserDefaults.standard.bool(forKey: initializedKey) {
            if snapshotExistingFiles(in: dirURL) {
                UserDefaults.standard.set(true, forKey: initializedKey)
            } else {
                revertEnabled()
                return
            }
        }

        logInfo("VoiceMemosWatcher: Starting to watch \(dirURL.path)")

        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else {
            logError("VoiceMemosWatcher: Failed to open directory for monitoring")
            showFullDiskAccessAlert()
            revertEnabled()
            return
        }
        directoryFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.directoryFileDescriptor, fd >= 0 {
                close(fd)
                self?.directoryFileDescriptor = -1
            }
        }

        dispatchSource = source
        source.resume()

        // Initial scan for files that arrived while the app was not running
        watchQueue.async { [weak self] in
            self?.handleDirectoryChange()
        }
    }

    private func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    // MARK: - Directory Change Handling

    private func handleDirectoryChange() {
        guard let dirURL = voiceMemosDirectoryURL else { return }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let newFiles = contents.filter { url in
                watchedExtensions.contains(url.pathExtension.lowercased())
                    && !processedFileNames.contains(url.lastPathComponent)
            }

            for file in newFiles {
                logInfo("VoiceMemosWatcher: Detected new file: \(file.lastPathComponent)")
                waitForStableFileSize(file) { [weak self] stableURL in
                    self?.queueForTranscription(stableURL)
                }
            }
        } catch {
            logError("VoiceMemosWatcher: Error scanning directory: \(error)")
        }
    }

    // MARK: - File Stability Check

    private func waitForStableFileSize(_ url: URL, attempt: Int = 0, previousSize: Int64? = nil, completion: @escaping (URL) -> Void) {
        let maxAttempts = 30 // 30 × 2s = 60s max wait
        guard attempt < maxAttempts else {
            logWarning("VoiceMemosWatcher: File size did not stabilize: \(url.lastPathComponent)")
            markAsProcessed(url)
            return
        }

        guard let currentSize = fileSize(at: url) else {
            logWarning("VoiceMemosWatcher: Cannot read file size for \(url.lastPathComponent)")
            return
        }

        if let prev = previousSize, prev == currentSize, currentSize > 0 {
            logInfo("VoiceMemosWatcher: File size stable at \(currentSize) bytes: \(url.lastPathComponent)")
            completion(url)
        } else {
            watchQueue.asyncAfter(deadline: .now() + fileSizeStabilityDelay) { [weak self] in
                self?.waitForStableFileSize(url, attempt: attempt + 1, previousSize: currentSize, completion: completion)
            }
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    // MARK: - Transcription Queue

    private func queueForTranscription(_ url: URL) {
        markAsProcessed(url)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingFiles.append(url)
            self.processNextInQueue()
        }
    }

    private func processNextInQueue() {
        guard !pendingFiles.isEmpty, !isProcessing else { return }

        // Yield to user-initiated transcriptions
        guard let tm = transcriptionManager, !tm.isTranscribing else {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.processNextInQueue()
            }
            return
        }

        let fileURL = pendingFiles.removeFirst()

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logWarning("VoiceMemosWatcher: File no longer exists, skipping: \(fileURL.lastPathComponent)")
            processNextInQueue()
            return
        }

        isProcessing = true
        logInfo("VoiceMemosWatcher: Starting transcription for: \(fileURL.lastPathComponent)")

        tm.transcribeWithRetry(audioURL: fileURL) { [weak self] text in
            guard let self = self else { return }

            DispatchQueue.main.async {
                self.isProcessing = false

                if let text = text {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    logInfo("VoiceMemosWatcher: Transcription complete (\(trimmed.count) chars)")
                    self.transcriptionManager?.handleTranscriptionOutput(trimmed)
                } else {
                    logError("VoiceMemosWatcher: Transcription failed for \(fileURL.lastPathComponent)")
                }

                self.processNextInQueue()
            }
        }
    }

    // MARK: - Processed Files Persistence

    @discardableResult
    private func snapshotExistingFiles(in dirURL: URL) -> Bool {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            let audioFiles = contents.filter { url in
                watchedExtensions.contains(url.pathExtension.lowercased())
            }

            for file in audioFiles {
                processedFileNames.insert(file.lastPathComponent)
            }

            persistProcessedFiles()
            logInfo("VoiceMemosWatcher: Snapshotted \(audioFiles.count) existing files as already processed")
            return true
        } catch {
            logError("VoiceMemosWatcher: Error snapshotting existing files: \(error)")
            return false
        }
    }

    private func markAsProcessed(_ url: URL) {
        processedFileNames.insert(url.lastPathComponent)
        persistProcessedFiles()
    }

    private func loadProcessedFiles() {
        if let stored = UserDefaults.standard.array(forKey: processedFilesKey) as? [String] {
            processedFileNames = Set(stored)
        }
    }

    private func persistProcessedFiles() {
        UserDefaults.standard.set(Array(processedFileNames), forKey: processedFilesKey)
    }

    // MARK: - Permission Checks

    private func hasDirectoryAccess(_ dirURL: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return true
        } catch {
            return false
        }
    }

    /// Reverts isEnabled without re-triggering didSet → startWatching.
    private func revertEnabled() {
        DispatchQueue.main.async {
            UserDefaults.standard.set(false, forKey: self.enabledKey)
            // Set backing storage directly to avoid didSet cycle
            self.isEnabled = false
        }
    }

    private func showFullDiskAccessAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Full Disk Access Required"
            alert.informativeText = "Ramblr needs Full Disk Access to read Voice Memos recordings. Please grant access in System Settings > Privacy & Security > Full Disk Access, then try enabling this feature again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func showNoVoiceMemosAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Voice Memos Not Found"
            alert.informativeText = "The Voice Memos recordings directory doesn't exist. Please record a Voice Memo first, then try enabling this feature."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
