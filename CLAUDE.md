# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ramblr is a native macOS menubar application for voice note recording and AI transcription. Built with Swift/SwiftUI, it uses OpenAI Whisper or Groq APIs for transcription.

- **Platform**: macOS 13+
- **Language**: Swift 5.10+
- **UI**: SwiftUI + AppKit (hybrid)
- **Build System**: Xcode 16.2+

## Build Commands

```bash
# Build release
xcodebuild -scheme Ramblr -configuration Release

# Build debug
xcodebuild -scheme Ramblr -configuration Debug
```

No external package manager dependencies - pure Swift/SwiftUI.

## Architecture

**Component-based architecture with clear separation of concerns:**

```
RamblrApp (entry point)
    ├── RecordingCoordinator (orchestrates recording flow)
    │   ├── AudioManager (microphone capture, PCM processing, compression)
    │   └── TranscriptionManager (API calls, retry logic, history)
    ├── HotkeyManager (global hotkeys via Carbon APIs)
    ├── MenuBarView (SwiftUI UI)
    └── WaveformIndicatorWindow (floating waveform display)
```

**Data Flow:**
1. User presses hotkey → HotkeyManager posts notification → RecordingCoordinator toggles recording
2. AudioManager captures audio → WaveformIndicatorWindow displays waveform
3. Recording stops → TranscriptionManager sends to API (with exponential backoff retries) → Result added to history
4. Optional auto-paste using Accessibility API

**State Management:**
- @Published properties for reactive UI updates
- UserDefaults for persistence (API keys, settings, history)
- Combine publishers for inter-component communication
- NotificationCenter for hotkey events

## Key Files

| File | Purpose |
|------|---------|
| `AudioManager.swift` | Audio capture, PCM buffer processing, adaptive compression |
| `TranscriptionManager.swift` | OpenAI/Groq API integration, retry logic, transcription history |
| `RecordingCoordinator.swift` | Orchestrates recording lifecycle, connects managers |
| `HotkeyManager.swift` | Global hotkey registration (Option+D start/stop, Option+C cancel) |
| `MenuBarView.swift` | Menubar dropdown UI, settings |
| `Logger.swift` | Singleton logger to ~/Library/Application Support/Ramblr/Ramblr.log |

## Important Notes

- **Menubar-only app**: LSUIElement = true (no dock icon)
- **Entitlements**: Requires accessibility permissions for auto-paste feature
- **Network resilience**: Adaptive audio compression based on network stress reporting
- **Silence detection**: Currently disabled (maximumSilencePercentage = 1.0) to avoid dropping wanted recordings
- **Debug logs**: ~/Library/Application Support/Ramblr/Ramblr.log
