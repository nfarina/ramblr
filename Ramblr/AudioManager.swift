import Foundation
import AVFoundation
import AppKit

class AudioManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var audioLevels: [Float] = []
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?
    private var volumeMeter: AVAudioMixerNode?
    private let audioQueue = DispatchQueue(label: "com.nfarina.Ramblr.audio")
    
    // Audio analysis parameters
    private var totalSamples: Int = 0
    private var silentSamples: Int = 0
    
    // Audio buffer for adaptive compression
    private var audioBufferMutex = NSLock()
    private var recordedAudioBuffer: [Int16] = []
    
    // Network quality adaptation
    @Published var networkStressLevel: Int = 0
    private var adaptiveQualityEnabled: Bool = true
    
    // This was a good idea but introduces the possibility of dropping a recording you want which is not acceptable,
    // so I've nerfed all the values.
    private let silenceThreshold: Float = 0.01 // Adjust this to change sensitivity
    private let minimumDuration: TimeInterval = 0.0 // Minimum recording duration in seconds
    private let maximumSilencePercentage: Float = 1.0 // Maximum percentage of silence allowed
    
    override init() {
        super.init()
        setupRecordingURL()
        requestMicrophoneAccess()
    }
    
    // MARK: - Network Stress Management
    
    /// Report network stress to adjust audio quality for future recordings
    func reportNetworkStress(level: Int) {
        logInfo("AudioManager: Network stress level set to \(level)")
        networkStressLevel = min(5, level) // Cap at level 5
        
        // Reset stress level after a delay if not updated
        DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self] in
            guard let self = self else { return }
            if self.networkStressLevel == level {
                self.networkStressLevel = max(0, self.networkStressLevel - 1)
                logInfo("AudioManager: Auto-reducing network stress level to \(self.networkStressLevel)")
            }
        }
    }
    
    // MARK: - Audio Recording Setup
    
    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            if granted {
                DispatchQueue.main.async {
                    self?.setupAudioEngine()
                }
            } else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Microphone Access Required"
                    alert.informativeText = "Ramblr needs microphone access to record audio for transcription. Please grant access in System Settings > Privacy & Security > Microphone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Cancel")
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
    
    private func setupRecordingURL() {
        let tempPath = URL(fileURLWithPath: "/tmp")
        recordingURL = tempPath.appendingPathComponent("ramble.wav")
        try? FileManager.default.removeItem(at: recordingURL!)
    }
    
    private func setupAudioEngine() {
        logInfo("AudioManager: Setting up audio engine")
        
        // Clean up existing engine if any
        cleanupAudioEngine()
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }
        
        inputNode = audioEngine.inputNode
        guard let inputNode = inputNode else {
            logError("AudioManager: Failed to get input node")
            return
        }
        
        volumeMeter = AVAudioMixerNode()
        guard let volumeMeter = volumeMeter else { return }
        
        audioEngine.attach(volumeMeter)
        
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 16000,
                                        channels: 1,
                                        interleaved: false)!
        
        logDebug("AudioManager: Input format: \(inputFormat)")
        logDebug("AudioManager: Whisper format: \(whisperFormat)")
        
        volumeMeter.volume = 1.0
        audioEngine.connect(inputNode, to: volumeMeter, format: inputFormat)
        audioEngine.prepare()
        
        // Reset the audio buffer
        audioBufferMutex.lock()
        recordedAudioBuffer.removeAll()
        audioBufferMutex.unlock()
        
        volumeMeter.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            self?.audioQueue.async { [weak self] in
                guard let self = self,
                      let recordingURL = self.recordingURL,
                      self.isRecording else { return }
                
                // Extract audio levels for waveform visualization
                self.extractAudioLevels(buffer)
                
                // Analyze audio buffer for silence
                self.analyzeSilence(buffer)
                
                // Process and store audio data in our buffer for adaptive compression
                self.processAudioBuffer(buffer)
                
                var convertedBuffer: AVAudioPCMBuffer?
                
                if self.converter == nil && inputFormat != whisperFormat {
                    self.converter = AVAudioConverter(from: inputFormat, to: whisperFormat)
                }
                
                if let converter = self.converter {
                    let frameCount = AVAudioFrameCount(Float(buffer.frameLength) * Float(16000) / Float(inputFormat.sampleRate))
                    convertedBuffer = AVAudioPCMBuffer(pcmFormat: whisperFormat,
                                                     frameCapacity: frameCount)
                    convertedBuffer?.frameLength = frameCount
                    
                    var error: NSError?
                    let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    
                    converter.convert(to: convertedBuffer!,
                                    error: &error,
                                    withInputFrom: inputBlock)
                    
                    if error != nil {
                        logError("AudioManager: Conversion error: \(error!)")
                        return
                    }
                } else {
                    convertedBuffer = buffer
                }
                
                guard let finalBuffer = convertedBuffer else { return }
                
                if self.audioFile == nil {
                    do {
                        self.audioFile = try AVAudioFile(forWriting: recordingURL,
                                                        settings: whisperFormat.settings)
                        logInfo("AudioManager: Created new audio file at \(recordingURL)")
                    } catch {
                        logError("AudioManager: Failed to create audio file: \(error)")
                        return
                    }
                }
                
                do {
                    try self.audioFile?.write(from: finalBuffer)
                } catch {
                    logError("AudioManager: Failed to write buffer: \(error)")
                }
            }
        }
    }
    
    // MARK: - Audio Buffer Processing
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Extract audio data and store it for potential compression later
        var newSamples = [Int16]()
        let frameCount = Int(buffer.frameLength)
        
        // Handle float data (most common format)
        if let floatData = buffer.floatChannelData, buffer.format.commonFormat == .pcmFormatFloat32 {
            let channelData = floatData[0]
            for i in 0..<frameCount {
                // Convert -1.0...1.0 float to int16 range
                let floatVal = channelData[Int(i)]
                let int16Val = Int16(max(-32768, min(32767, floatVal * 32767.0)))
                newSamples.append(int16Val)
            }
        } else if let int16Data = buffer.int16ChannelData, buffer.format.commonFormat == .pcmFormatInt16 {
            // Direct copy for int16 format
            let channelData = int16Data[0]
            newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        } else if let int32Data = buffer.int32ChannelData, buffer.format.commonFormat == .pcmFormatInt32 {
            // Convert int32 to int16
            let channelData = int32Data[0]
            for i in 0..<frameCount {
                let int32Val = channelData[Int(i)]
                let int16Val = Int16(max(-32768, min(32767, Int(int32Val) >> 16)))
                newSamples.append(int16Val)
            }
        }
        
        // Add to our buffer in a thread-safe way
        if !newSamples.isEmpty {
            audioBufferMutex.lock()
            recordedAudioBuffer.append(contentsOf: newSamples)
            audioBufferMutex.unlock()
        }
    }
    
    private func extractAudioLevels(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Calculate RMS (root mean square) for audio level
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        
        // Apply threshold to reduce noise during silence
        let threshold: Float = 0.002 // Slightly higher threshold to reduce sensitivity
        let level = rms > threshold ? min(1.0, rms * 30) : 0.02 // Balanced scaling, minimal baseline
        
        // Update levels on main thread for UI
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Keep a rolling buffer for visualization with slightly slower updates
            if self.audioLevels.count >= 15 {
                self.audioLevels.removeFirst()
            }
            self.audioLevels.append(level)
        }
    }
    
    private func analyzeSilence(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Count samples below threshold
        for i in 0..<frameLength {
            totalSamples += 1
            if abs(channelData[i]) < silenceThreshold {
                silentSamples += 1
            }
        }
    }
    
    private func isRecordingValid() -> Bool {
        // Check minimum duration (16000 samples per second for our format)
        let duration = TimeInterval(totalSamples) / 16000
        if duration < minimumDuration {
            logInfo("Recording too short: \(duration) seconds")
            return false
        }
        else {
            logInfo("Recording duration: \(duration) seconds")
        }
        
        // Check silence percentage
        let silencePercentage = Float(silentSamples) / Float(totalSamples)
        if silencePercentage > maximumSilencePercentage {
            logInfo("Too much silence: \(silencePercentage * 100)%")
            return false
        }
        else {
            logInfo("Silence percentage: \(silencePercentage * 100)%")
        }
        
        return true
    }
    
    private func cleanupAudioEngine() {
        logInfo("AudioManager: Cleaning up audio engine")
        audioEngine?.stop()
        volumeMeter?.removeTap(onBus: 0)
        audioEngine = nil
        inputNode = nil
        volumeMeter = nil
        converter = nil
        audioFile = nil
    }
    
    // MARK: - Recording Control
    
    func startRecording() {
        logInfo("AudioManager: Starting recording")
        
        // Initialize with full buffer of baseline levels to avoid left-to-right fill
        DispatchQueue.main.async { [weak self] in
            self?.audioLevels = Array(repeating: 0.02, count: 10)
        }
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Reset audio analysis
            self.totalSamples = 0
            self.silentSamples = 0
            
            // Make sure we have a fresh audio engine setup
            DispatchQueue.main.sync {
                self.setupAudioEngine()
            }
            
            guard let audioEngine = self.audioEngine else {
                logError("AudioManager: No audio engine available")
                return
            }
            
            try? FileManager.default.removeItem(at: self.recordingURL!)
            self.audioFile = nil
            
            do {
                try audioEngine.start()
                DispatchQueue.main.async {
                    self.isRecording = true
                    NotificationCenter.default.post(name: NSNotification.Name("RecordingStatusChanged"),
                                                 object: nil,
                                                 userInfo: ["isRecording": true])
                }
                logInfo("AudioManager: Recording started successfully")
            } catch {
                logError("AudioManager: Failed to start recording: \(error.localizedDescription)")
            }
        }
    }
    
    func stopRecording() -> URL? {
        logInfo("AudioManager: Stopping recording")
        guard let recordingURL = recordingURL else {
            logError("AudioManager: No recording URL available")
            return nil
        }
        
        // First mark as not recording to prevent new audio data from being processed
        isRecording = false
        
        // Clear audio levels
        DispatchQueue.main.async { [weak self] in
            self?.audioLevels.removeAll()
        }
        
        // Synchronously stop audio processing and close file
        audioQueue.sync { [weak self] in
            logInfo("AudioManager: Stopping audio engine and cleaning up")
            self?.audioEngine?.stop()
            self?.volumeMeter?.removeTap(onBus: 0)
            // Close the audio file explicitly
            if let audioFile = self?.audioFile {
                audioFile.close()
            }
            self?.audioFile = nil
            // Clean up the engine for next recording
            self?.cleanupAudioEngine()
        }
        
        NotificationCenter.default.post(name: NSNotification.Name("RecordingStatusChanged"),
                                     object: nil,
                                     userInfo: ["isRecording": false])
        
        // Check if the recording is valid
        if !isRecordingValid() {
            try? FileManager.default.removeItem(at: recordingURL)
            return nil
        }
        
        // Apply adaptive compression based on network stress level
        if adaptiveQualityEnabled && networkStressLevel > 0 {
            compressAudioFile(at: recordingURL)
        }
        
        // Verify the file exists before returning
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            logInfo("AudioManager: Recording saved successfully at \(recordingURL)")
            return recordingURL
        }
        logError("AudioManager: Recording file not found at \(recordingURL)")
        return nil
    }

    
    
    // MARK: - Audio Compression
    
    private func compressAudioFile(at url: URL) {
        audioBufferMutex.lock()
        let buffer = recordedAudioBuffer
        audioBufferMutex.unlock()
        
        if buffer.isEmpty {
            logError("AudioManager: No audio data available for compression")
            return
        }
        
        logInfo("AudioManager: Compressing audio with network stress level \(networkStressLevel)")
        
        do {
            // First, remove the existing file
            try? FileManager.default.removeItem(at: url)
            
            // Determine target sample rate based on network stress
            let baseRate: Double = 16000.0 // 16kHz (Whisper's preferred rate)
            let targetSampleRate: Double = max(8000.0, baseRate - (Double(networkStressLevel) * 2000.0))
            
            logInfo("AudioManager: Adaptive quality - Using sample rate \(Int(targetSampleRate))Hz")
            
            // Create format with explicit settings for smaller file size
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            
            // Calculate compression ratio
            let compressionRatio = 16000.0 / targetSampleRate
            _ = Int(Double(buffer.count) / compressionRatio)
            
            // Simple downsampling by taking every Nth sample
            var downsampledBuffer = [Int16]()
            let skipFactor = Int(round(compressionRatio))
            
            // For level 1, we may just write the buffer as is
            if skipFactor <= 1 {
                downsampledBuffer = buffer
            } else {
                for i in stride(from: 0, to: buffer.count, by: skipFactor) {
                    if i < buffer.count {
                        downsampledBuffer.append(buffer[i])
                    }
                }
            }
            
            if downsampledBuffer.isEmpty {
                logError("AudioManager: Downsampled buffer is empty; skipping compression")
                return
            }
            
            // Create audio format
            guard let format = AVAudioFormat(settings: settings) else {
                logError("AudioManager: Failed to create audio format for compression (sample rate \(targetSampleRate))")
                return
            }
            
            // Create PCM buffer
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(downsampledBuffer.count)) else {
                logError("AudioManager: Failed to create PCM buffer")
                return
            }
            
            pcmBuffer.frameLength = AVAudioFrameCount(downsampledBuffer.count)
            
            // Get channel data pointers
            guard let channelData = pcmBuffer.int16ChannelData else {
                logError("AudioManager: Failed to get channel data")
                return
            }
            
            // Copy audio data
            for i in 0..<downsampledBuffer.count {
                channelData[0][i] = downsampledBuffer[i]
            }
            
            // Create audio file
            let audioFile = try AVAudioFile(forWriting: url, settings: settings)
            try audioFile.write(from: pcmBuffer)
            
            // Log file size
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int64 {
                logInfo("AudioManager: Compressed audio file size: \(size) bytes (\(size/1024) KB)")
            }
        } catch {
            logError("AudioManager: Failed to compress audio: \(error)")
        }
        
        // Clear buffer after use
        audioBufferMutex.lock()
        recordedAudioBuffer.removeAll()
        audioBufferMutex.unlock()
    }
}
