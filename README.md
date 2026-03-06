<img width="238" height="305" alt="F01A9123-02DF-45FF-A7DB-D9DFCC01F312" src="https://github.com/user-attachments/assets/9294d9a5-3506-404b-a156-0b39d50151dc" />


# Ramblr

Are you spending time composing your thoughts, then typing them carefully into the "prompt" box for an AI like ChatGPT, Cursor, or Claude Code?

Stop that!

AI doesn't need your thoughts and instructions all nicely written out like this README is for humans. Rambling is better! Here's an example:

<img width="512" height="512" alt="Ramblr ramble" src="https://github.com/user-attachments/assets/44f9a7ab-34c2-4780-9c58-747dd1e37afb"/>

Wow, that's a lot of text to read - but AI is *great* at reading lots of text like this, and this text is _full_ of useful information. Rambles better represent your true state of mind: you might repeat yourself if you're sure about something, or waffle when you're not. That's all signal.

The best way to ramble is to start recording, then just click around your codebase, rattling off file names like "look in admin site dot tsx" or component/function names, or anything that you'd tell a human. Or start recording _before_ you even begin reviewing an AI's response, then just blab your thoughts while you're looking over its work. When you're done reviewing, Ramblr will transcribe your blatherings using the Whisper API with astonishing accuracy.

Ramblr is a native macOS app that lives in your menubar. All you need to do is download the app and paste your ~[OpenAI API key](https://platform.openai.com/api-keys)~ [Groq API Key](https://console.groq.com/keys) (You can use OpenAI's API, but Groq is much, _much_ faster for the same quality service). That's Groq-with-a-Q, _not_ xAI's Grok.

<img width="340" height="474" alt="Ramblr ramble" src="https://github.com/user-attachments/assets/80b456f5-36de-438d-b8e5-d4e4a196aea9" />

## Features

- Global customizable hotkeys to start/stop recording
- Near-perfect transcription via Whisper API
- Copies to clipboard and notifies with sound when ready to paste, or auto-paste into active app
- History of the last 10 transcriptions for quick re-copy
- Can auto-save transcriptions to a folder
- Can auto-pause music while recording
- Can auto-import Voice Memos from Mac (or iOS via iCloud sync)

## Wait, doesn't this already exist?

[Yes](https://superwhisper.com), [yes](https://goodsnooze.gumroad.com/l/macwhisper), [yes](https://wisprflow.ai). But I have problems with them all:

- They all want to lock you into a subscription model. For dictation!
- They either use a local transcription model (not as accurate, or slower) or the exact same Whisper API Ramblr uses (that's the real magic here)

I just wanted something I could use at cost. So I vibe-coded Ramblr. It's free to download and use! You just pay Groq/OpenAI directly for the Whisper API, which is pennies (my last monthly bill from Groq was $0.04).

## Requirements

- macOS 13 or later
- OpenAI API key

## Download

You can [download the latest release here](https://github.com/nfarina/ramblr/releases) or just build it yourself from source in Xcode.

## Privacy & Storage

- Audio is recorded to a temporary file during recording and removed after
- Transcription history (last 10 items) and the API key are stored in UserDefaults
- Logs are written to `~/Library/Application Support/Ramblr/Ramblr.log`

## License

MIT License — see `LICENSE.txt`
