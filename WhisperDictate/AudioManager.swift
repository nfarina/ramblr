import Foundation
import AVFoundation
import AppKit

class AudioManager: NSObject, ObservableObject {
    @Published var isRecording = false
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?
    private var volumeMeter: AVAudioMixerNode?
    private let audioQueue = DispatchQueue(label: "com.nfarina.WhisperDictate.audio")
    
    // Audio analysis parameters
    private var totalSamples: Int = 0
    private var silentSamples: Int = 0
    private let silenceThreshold: Float = 0.01 // Adjust this to change sensitivity
    private let minimumDuration: TimeInterval = 1.0 // Minimum recording duration in seconds
    private let maximumSilencePercentage: Float = 1.0 // Maximum percentage of silence allowed
    
    override init() {
        super.init()
        setupRecordingURL()
        requestMicrophoneAccess()
    }
    
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
                    alert.informativeText = "WhisperDictate needs microphone access to record audio for transcription. Please grant access in System Settings > Privacy & Security > Microphone."
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
        recordingURL = tempPath.appendingPathComponent("whisper-dictate-recording.wav")
        try? FileManager.default.removeItem(at: recordingURL!)
    }
    
    private func setupAudioEngine() {
        print("AudioManager: Setting up audio engine")
        
        // Clean up existing engine if any
        cleanupAudioEngine()
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }
        
        inputNode = audioEngine.inputNode
        guard let inputNode = inputNode else {
            print("AudioManager: Failed to get input node")
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
        
        print("AudioManager: Input format: \(inputFormat)")
        print("AudioManager: Whisper format: \(whisperFormat)")
        
        volumeMeter.volume = 1.0
        audioEngine.connect(inputNode, to: volumeMeter, format: inputFormat)
        audioEngine.prepare()
        
        volumeMeter.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            self?.audioQueue.async { [weak self] in
                guard let self = self,
                      let recordingURL = self.recordingURL,
                      self.isRecording else { return }
                
                // Analyze audio buffer for silence
                self.analyzeSilence(buffer)
                
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
                        print("AudioManager: Conversion error: \(error!)")
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
                        print("AudioManager: Created new audio file at \(recordingURL)")
                    } catch {
                        print("AudioManager: Failed to create audio file: \(error)")
                        return
                    }
                }
                
                do {
                    try self.audioFile?.write(from: finalBuffer)
                } catch {
                    print("AudioManager: Failed to write buffer: \(error)")
                }
            }
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
            print("Recording too short: \(duration) seconds")
            return false
        }
        
        // Check silence percentage
        let silencePercentage = Float(silentSamples) / Float(totalSamples)
        if silencePercentage > maximumSilencePercentage {
            print("Too much silence: \(silencePercentage * 100)%")
            return false
        }
        
        return true
    }
    
    private func cleanupAudioEngine() {
        print("AudioManager: Cleaning up audio engine")
        audioEngine?.stop()
        volumeMeter?.removeTap(onBus: 0)
        audioEngine = nil
        inputNode = nil
        volumeMeter = nil
        converter = nil
        audioFile = nil
    }
    
    func startRecording() {
        print("AudioManager: Starting recording")
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
                print("AudioManager: No audio engine available")
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
                print("AudioManager: Recording started successfully")
            } catch {
                print("AudioManager: Failed to start recording: \(error.localizedDescription)")
            }
        }
    }
    
    func stopRecording() -> URL? {
        print("AudioManager: Stopping recording")
        guard let recordingURL = recordingURL else {
            print("AudioManager: No recording URL available")
            return nil
        }
        
        // First mark as not recording to prevent new audio data from being processed
        isRecording = false
        
        // Synchronously stop audio processing and close file
        audioQueue.sync { [weak self] in
            print("AudioManager: Stopping audio engine and cleaning up")
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
        
        // Verify the file exists before returning
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            print("AudioManager: Recording saved successfully at \(recordingURL)")
            return recordingURL
        }
        print("AudioManager: Recording file not found at \(recordingURL)")
        return nil
    }
}
