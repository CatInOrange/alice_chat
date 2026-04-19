# AliceChat

Android-first chat client for connecting to OpenClaw, with a future Windows target.

## Goal

Build a lightweight cross-platform chat app that:
- prioritizes Android first
- can later ship on Windows from the same codebase
- uses Flyer Chat as the UI foundation
- connects to an OpenClaw-compatible backend over HTTP/WebSocket

## Current status

This repo currently contains an architecture-first Flutter scaffold because the host does not yet have Flutter/Android SDK installed.

The base includes:
- proposed Flutter project structure
- Flyer Chat integration plan
- OpenClaw transport abstraction
- Android-first implementation notes
- app skeleton files for the first coding pass

## Planned stack

- **Framework:** Flutter
- **Chat UI:** `flutter_chat_ui` + `flutter_chat_core` (Flyer Chat)
- **Realtime transport:** WebSocket
- **History/API:** HTTP REST
- **Targets:** Android first, Windows second

## Proposed MVP

1. Single chat session list
2. Message timeline
3. Text input and send
4. Stream assistant replies from OpenClaw
5. Basic connection settings page
6. Local persistence for session metadata

## Suggested next step

Install Flutter + Android SDK, then run:

```bash
flutter create . --platforms=android,windows
flutter pub add flutter_chat_ui flutter_chat_core uuid intl web_socket_channel http shared_preferences
```

Then wire the files in `docs/` and `lib/` from this scaffold.

## Repo layout

```text
AliceChat/
├── README.md
├── docs/
│   └── architecture.md
├── lib/
│   ├── main.dart
│   ├── app/
│   │   ├── app.dart
│   │   └── theme.dart
│   ├── features/
│   │   ├── chat/
│   │   └── settings/
│   └── core/
│       └── openclaw/
└── pubspec.template.yaml
```

## Notes

Flyer Chat is backend-agnostic and fits this use case well, especially for OpenClaw-style assistant/chat streaming.
