//
//  WhisperDictateApp.swift
//  WhisperDictate
//
//  Created by Nick Farina on 12/22/24.
//

import SwiftUI
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Just ensure we're not active
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }
}

@main
struct WhisperDictateApp: App {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var hotkeyManager = HotkeyManager()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var coordinator: RecordingCoordinator
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        print("WhisperDictateApp: Initializing")
        
        // Create managers first
        let audio = AudioManager()
        let hotkey = HotkeyManager()
        let transcription = TranscriptionManager()
        
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
