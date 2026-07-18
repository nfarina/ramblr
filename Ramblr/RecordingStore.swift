import Foundation
import Combine

enum RecordingStatus: String, Codable {
    case recording
    case ready
    case transcribing
    case succeeded
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .recording: return "Recording"
        case .ready: return "Ready"
        case .transcribing: return "Transcribing"
        case .succeeded: return "Transcribed"
        case .failed: return "Needs attention"
        case .cancelled: return "Cancelled"
        }
    }
}

enum RecordingRetentionPolicy: String, CaseIterable, Identifiable {
    case immediately
    case oneDay
    case sevenDays
    case forever

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .immediately: return "Delete after transcription"
        case .oneDay: return "24 hours"
        case .sevenDays: return "7 days"
        case .forever: return "Until I delete them"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .immediately: return 0
        case .oneDay: return 24 * 60 * 60
        case .sevenDays: return 7 * 24 * 60 * 60
        case .forever: return nil
        }
    }
}

struct StoredRecording: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    var completedAt: Date?
    var updatedAt: Date
    var status: RecordingStatus
    var filename: String
    var duration: TimeInterval?
    var fileSize: Int64?
    var model: String?
    var transcript: String?
    var isPermanent: Bool

    var displayTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}

/// Owns microphone recordings independently of app/process lifetime.
///
/// Original audio is durable and short-lived; upload chunks remain disposable.
/// Metadata is stored separately so a relaunch or app update can recover retries.
final class RecordingStore: ObservableObject {
    static let retentionDefaultsKey = "RecordingRetentionPolicy"
    static let storageLimitDefaultsKey = "RecordingStorageLimitMB"

    @Published private(set) var recordings: [StoredRecording] = []
    @Published private(set) var storageBytes: Int64 = 0
    @Published private(set) var retentionPolicy: RecordingRetentionPolicy
    @Published private(set) var storageLimitMB: Int

    let recordingsDirectory: URL

    private let fileManager: FileManager
    private let metadataURL: URL
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults

        let applicationSupport = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Ramblr", isDirectory: true)
        recordingsDirectory = applicationSupport.appendingPathComponent("Recordings", isDirectory: true)
        metadataURL = recordingsDirectory.appendingPathComponent("index.json")

        retentionPolicy = RecordingRetentionPolicy(
            rawValue: defaults.string(forKey: Self.retentionDefaultsKey) ?? ""
        ) ?? .oneDay
        let configuredLimit = defaults.integer(forKey: Self.storageLimitDefaultsKey)
        storageLimitMB = configuredLimit > 0 ? configuredLimit : 500

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        createDirectoryIfNeeded()
        loadAndRecover()
        cleanupExpiredRecordings()
    }

    func beginRecording() throws -> URL {
        try fileManager.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: recordingsDirectory.path
        )
        let id = UUID()
        let filename = "ramblr-\(id.uuidString).m4a"
        let now = Date()
        let recording = StoredRecording(
            id: id,
            createdAt: now,
            completedAt: nil,
            updatedAt: now,
            status: .recording,
            filename: filename,
            duration: nil,
            fileSize: nil,
            model: nil,
            transcript: nil,
            isPermanent: false
        )
        recordings.insert(recording, at: 0)
        persist()
        return recordingsDirectory.appendingPathComponent(filename)
    }

    func recording(for url: URL) -> StoredRecording? {
        let standardizedURL = url.standardizedFileURL
        return recordings.first {
            audioURL(for: $0).standardizedFileURL == standardizedURL
        }
    }

    func audioURL(for recording: StoredRecording) -> URL {
        recordingsDirectory.appendingPathComponent(recording.filename)
    }

    func markReady(url: URL, duration: TimeInterval?) {
        update(url: url) { recording in
            recording.status = .ready
            recording.completedAt = Date()
            recording.duration = duration
            recording.fileSize = self.fileSize(at: url)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func markTranscribing(url: URL, model: String) {
        update(url: url) { recording in
            recording.status = .transcribing
            recording.model = model
        }
    }

    func markSucceeded(url: URL, model: String, transcript: String) {
        update(url: url) { recording in
            recording.status = .succeeded
            recording.model = model
            recording.transcript = transcript
        }
        cleanupExpiredRecordings()
    }

    func markFailed(url: URL, model: String? = nil) {
        update(url: url) { recording in
            recording.status = .failed
            if let model { recording.model = model }
        }
    }

    func markCancelled(url: URL) {
        update(url: url) { recording in
            recording.status = .cancelled
            recording.completedAt = recording.completedAt ?? Date()
            recording.fileSize = self.fileSize(at: url)
        }
    }

    func markPermanent(_ recording: StoredRecording) {
        update(id: recording.id) { $0.isPermanent = true }
    }

    func delete(_ recording: StoredRecording) {
        delete(id: recording.id)
    }

    func delete(url: URL) {
        guard let recording = recording(for: url) else {
            try? fileManager.removeItem(at: url)
            return
        }
        delete(recording)
    }

    func setRetentionPolicy(_ policy: RecordingRetentionPolicy) {
        retentionPolicy = policy
        defaults.set(policy.rawValue, forKey: Self.retentionDefaultsKey)
        cleanupExpiredRecordings()
    }

    func setStorageLimitMB(_ limit: Int) {
        storageLimitMB = max(50, limit)
        defaults.set(storageLimitMB, forKey: Self.storageLimitDefaultsKey)
        cleanupExpiredRecordings()
    }

    func cleanupExpiredRecordings(now: Date = Date()) {
        var idsToDelete = Set<UUID>()

        if let retentionInterval = retentionPolicy.timeInterval {
            for recording in recordings where isAutomaticallyDisposable(recording) {
                let referenceDate = recording.updatedAt
                if now.timeIntervalSince(referenceDate) >= retentionInterval {
                    idsToDelete.insert(recording.id)
                }
            }
        }

        for id in idsToDelete {
            deleteFilesOnly(id: id)
        }
        recordings.removeAll { idsToDelete.contains($0.id) }

        refreshStorageBytes()
        let limitBytes = Int64(storageLimitMB) * 1024 * 1024
        if storageBytes > limitBytes {
            let oldestDisposable = recordings
                .filter(isAutomaticallyDisposable)
                .sorted { $0.updatedAt < $1.updatedAt }
            for recording in oldestDisposable where storageBytes > limitBytes {
                let size = fileSize(at: audioURL(for: recording)) ?? 0
                deleteFilesOnly(id: recording.id)
                recordings.removeAll { $0.id == recording.id }
                storageBytes = max(0, storageBytes - size)
            }
        }

        persist()
        refreshStorageBytes()
    }

    private func isAutomaticallyDisposable(_ recording: StoredRecording) -> Bool {
        guard !recording.isPermanent else { return false }
        return recording.status == .succeeded || recording.status == .cancelled
    }

    private func update(url: URL, mutation: (inout StoredRecording) -> Void) {
        guard let id = recording(for: url)?.id else { return }
        update(id: id, mutation: mutation)
    }

    private func update(id: UUID, mutation: (inout StoredRecording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&recordings[index])
        recordings[index].updatedAt = Date()
        recordings.sort { $0.createdAt > $1.createdAt }
        persist()
        refreshStorageBytes()
    }

    private func delete(id: UUID) {
        deleteFilesOnly(id: id)
        recordings.removeAll { $0.id == id }
        persist()
        refreshStorageBytes()
    }

    private func deleteFilesOnly(id: UUID) {
        guard let recording = recordings.first(where: { $0.id == id }) else { return }
        try? fileManager.removeItem(at: audioURL(for: recording))
    }

    private func createDirectoryIfNeeded() {
        do {
            try fileManager.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: recordingsDirectory.path
            )
        } catch {
            logError("RecordingStore: Failed to create recordings directory: \(error)")
        }
    }

    private func loadAndRecover() {
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? decoder.decode([StoredRecording].self, from: data) {
            recordings = decoded
        }

        let knownFilenames = Set(recordings.map(\.filename))
        if let contents = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in contents where url.pathExtension.lowercased() == "m4a" && !knownFilenames.contains(url.lastPathComponent) {
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                let createdAt = values?.creationDate ?? Date()
                recordings.append(StoredRecording(
                    id: UUID(),
                    createdAt: createdAt,
                    completedAt: createdAt,
                    updatedAt: Date(),
                    status: .ready,
                    filename: url.lastPathComponent,
                    duration: nil,
                    fileSize: values?.fileSize.map(Int64.init),
                    model: nil,
                    transcript: nil,
                    isPermanent: false
                ))
            }
        }

        var recoveredCount = 0
        for index in recordings.indices {
            let url = audioURL(for: recordings[index])
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if recordings[index].status == .recording {
                recordings[index].status = .ready
                recordings[index].completedAt = recordings[index].completedAt ?? Date()
                recordings[index].updatedAt = Date()
                recordings[index].fileSize = fileSize(at: url)
                recoveredCount += 1
            } else if recordings[index].status == .transcribing {
                recordings[index].status = .failed
                recordings[index].updatedAt = Date()
                recoveredCount += 1
            }
        }

        recordings.removeAll { !fileManager.fileExists(atPath: audioURL(for: $0).path) }
        recordings.sort { $0.createdAt > $1.createdAt }
        if recoveredCount > 0 {
            logInfo("RecordingStore: Recovered \(recoveredCount) recording(s) after relaunch")
        }
        persist()
        refreshStorageBytes()
    }

    private func persist() {
        do {
            let data = try encoder.encode(recordings)
            try data.write(to: metadataURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        } catch {
            logError("RecordingStore: Failed to save metadata: \(error)")
        }
    }

    private func refreshStorageBytes() {
        storageBytes = recordings.reduce(0) { total, recording in
            total + (fileSize(at: audioURL(for: recording)) ?? 0)
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.int64Value
    }
}
