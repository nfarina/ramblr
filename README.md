# WhisperDictate

![icon_128x128](https://github.com/user-attachments/assets/4780e5f1-e609-45f8-acb9-e4e8053461e1)

A macOS menu bar app that lets you dictate text anywhere using OpenAI's Whisper API. Just press a hotkey, speak, and your words will be typed wherever your cursor is.

## Features

- 🎙️ Quick recording with global hotkey (⌘+Shift+R)
- 🤖 Fast, accurate transcription using OpenAI's Whisper API
- ⌨️ Types text directly into any app
- 🔒 Secure API key storage
- 🖥️ Clean menu bar interface
- 📝 Works in any text field or editor

## Requirements

- macOS 13.0 or later
- OpenAI API key
- Xcode 15+ (for building)

## Setup

1. Clone the repository
2. Open `WhisperDictate.xcodeproj` in Xcode
3. Build and run
4. Click the microphone icon in the menu bar
5. Enter your OpenAI API key in settings
6. Grant accessibility permissions when prompted

## Usage

1. Place your cursor where you want to type
2. Press ⌘+Shift+R (or click Record in the menu)
3. Speak clearly
4. Release the hotkey to stop recording
5. Wait for transcription (1-2 seconds)
6. Your text will be typed automatically

## Privacy & Security

- Your API key is stored securely in macOS Keychain
- Audio is processed through OpenAI's Whisper API
- No audio is stored locally after transcription
- Requires accessibility permissions to type text

## Building from Source

```bash
git clone https://github.com/yourusername/whisper-dictate.git
cd whisper-dictate
open WhisperDictate.xcodeproj
```

## Contributing

Contributions are welcome! Some ideas for improvements:

- Customizable hotkeys
- Transcription history
- Different Whisper models
- Language selection
- Auto-punctuation options

## License

MIT License - see LICENSE file for details

## Acknowledgments

- [OpenAI Whisper](https://openai.com/research/whisper) for the amazing speech recognition
- [SwiftUI](https://developer.apple.com/xcode/swiftui/) for the native macOS interface
- [Codeium's Cascade](https://codeium.com) for pair programming assistance in building this app
