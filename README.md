# Thoughtaker app

The Android app for the [Thoughtaker pendant](https://github.com/NarForDev/thoughtakerpendant): a wearable that
records your conversations. The app syncs the recordings, transcribes them, works out who said what, and turns the
tasks, promises and plans in them into reminders and calendar entries. Everything runs on the phone; no audio or text
is sent to a server.

## What it does

**Recording**
- Pair the pendant once; it then syncs in the background, even with the app closed
- Battery, storage, sync status and mute, from the app
- Turn the "Perthro" wake word on or off, once the pendant firmware has it

**Understanding**
- Transcribes speech on the phone with Whisper (English mixed with Indian languages works)
- Labels who said what, and learns which voice is yours, so your lines show as "You"
- Pulls out tasks, promises you made, promises made to you, events, decisions and facts, each linked to the moment it
  was said
- Ignores TV, music and chatter: captions, fragments and copied lines are dropped, a due date is kept only if someone
  said when, and once it knows your voice, conversations you were not part of are skipped

**Your day**
- Today: talk time, a summary of the day and what is due next
- Timeline of conversations with playback and bookmarks
- Search by words, people or topics

**Acting**
- Reminders before deadlines
- Only your own dated plans and deadlines go into the phone calendar, and they leave it when done
- Drafts the email or message you promised to send

**Privacy**
- Delete a conversation, a day or everything
- Download models on Wi-Fi only; transcribe and understand only while charging
- The link to the pendant is encrypted

## On-device models

Downloaded once from pinned URLs and checked against SHA-256 before use:

| Model | Size | Job |
|---|---|---|
| Silero VAD | 0.6 MB | finds speech |
| Whisper base (int8), via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 160 MB | transcription |
| CAM++ speaker embeddings | 28 MB | who said what |
| Qwen3-1.7B Q4_K_M, via llama.cpp ([llamadart](https://pub.dev/packages/llamadart)) | 1.1 GB | items, daily summaries, topics |

## Build

Needs Flutter (Dart 3.14+), JDK 17 and the Android SDK with platform 36. Minimum Android version is 8.0 (API 26).

```sh
flutter pub get
flutter test
flutter run            # or: flutter build apk
```

`android/gradle.properties` sets `kotlin.incremental=false`, which avoids Kotlin build failures when the pub cache
and the project are on different drives on Windows.

## How it is built

```
lib/
  pendant.dart, protocol.dart, adpcm.dart   BLE sync with the pendant (see docs/protocol.md)
  db.dart                                   SQLite + FTS5: chunks, transcripts, speakers, items, summaries
  conversations.dart, voices.dart           grouping chunks into conversations; voiceprint maths
  ai/          transcription (VAD, Whisper, CAM++), understanding (Qwen3), model downloads
  acting/      reminders, calendar sync, share and email drafts
  screens/     Today, Timeline, To-dos, Search, Pendant, Settings, onboarding, voice profile
  ui/          theme, widgets and painters
android/       foreground service for background sync, calendar and intent channels (Kotlin)
docs/protocol.md   pendant <-> phone contract, identical to the copy in the pendant repo
```

Work is queued in the database (a chunk waits until it is transcribed, then until it is understood), so processing
picks up where it left off after the app is killed. Deleted chunks leave a tombstone so the pendant never syncs them
back.

## Status

Tested on a Samsung Galaxy S24 with the breadboard pendant prototype. Android only for now.
