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
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recordingURL = documentsPath.appendingPathComponent("recording.wav")
        try? FileManager.default.removeItem(at: recordingURL!)
    }
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        
        guard let audioEngine = audioEngine else { return }
        
        inputNode = audioEngine.inputNode
        guard let inputNode = inputNode else { return }
        
        volumeMeter = AVAudioMixerNode()
        guard let volumeMeter = volumeMeter else { return }
        
        audioEngine.attach(volumeMeter)
        
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 16000,
                                        channels: 1,
                                        interleaved: false)!
        
        volumeMeter.volume = 1.0
        audioEngine.connect(inputNode, to: volumeMeter, format: inputFormat)
        audioEngine.prepare()
        
        volumeMeter.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self,
                  let recordingURL = self.recordingURL else { return }
            
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
                
                if error != nil { return }
            } else {
                convertedBuffer = buffer
            }
            
            guard let finalBuffer = convertedBuffer else { return }
            
            if self.audioFile == nil {
                do {
                    self.audioFile = try AVAudioFile(forWriting: recordingURL,
                                                    settings: whisperFormat.settings)
                } catch {
                    return
                }
            }
            
            try? self.audioFile?.write(from: finalBuffer)
        }
    }
    
    func startRecording() {
        guard let audioEngine = audioEngine else { return }
        
        try? FileManager.default.removeItem(at: recordingURL!)
        audioFile = nil
        
        do {
            try audioEngine.start()
            isRecording = true
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStatusChanged"),
                                         object: nil,
                                         userInfo: ["isRecording": true])
        } catch {
            print("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() -> URL? {
        guard let recordingURL = recordingURL else { return nil }
        
        audioEngine?.stop()
        volumeMeter?.removeTap(onBus: 0)
        audioFile = nil
        isRecording = false
        
        NotificationCenter.default.post(name: NSNotification.Name("RecordingStatusChanged"),
                                     object: nil,
                                     userInfo: ["isRecording": false])
        
        setupAudioEngine()
        return recordingURL
    }
}
