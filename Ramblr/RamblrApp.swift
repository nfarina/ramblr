import SwiftUI
import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        logInfo("Application did finish launching")
        // Just ensure we're not active
        if NSApp.isActive {
            NSApp.deactivate()
        }
        // Ensure notifications show while app is active/agent
        UNUserNotificationCenter.current().delegate = self
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        logInfo("Application will terminate")
    }

    // Show alert/banner even if app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@main
struct RamblrApp: App {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var hotkeyManager = HotkeyManager()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var coordinator: RecordingCoordinator
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Initialize Logger early
    private let logger = Logger.shared
    
    init() {
        logInfo("RamblrApp: Initializing")
        
        // Create managers first
        let audio = AudioManager()
        // Create transcription manager with audio manager reference
        let transcription = TranscriptionManager(audioManager: audio)
        let hotkey = HotkeyManager()
        
        // Initialize coordinator with the same instances
        let coordinator = RecordingCoordinator(
            audioManager: audio,
            transcriptionManager: transcription
        )
        
        // Now create the StateObjects
        _audioManager = StateObject(wrappedValue: audio)
        _hotkeyManager = StateObject(wrappedValue: hotkey)
        _transcriptionManager = StateObject(wrappedValue: transcription)
        _coordinator = StateObject(wrappedValue: coordinator)
        
        // Log system info
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        logInfo("System: \(osVersion), App Version: \(appVersion)")
    }
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarView(audioManager: audioManager,
                       hotkeyManager: hotkeyManager,
                       transcriptionManager: transcriptionManager,
                       coordinator: coordinator)
        } label: {
            if audioManager.isRecording {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.multicolor)
            } else if transcriptionManager.isTranscribing {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.yellow)
            } else {
                Image(systemName: "mic.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
