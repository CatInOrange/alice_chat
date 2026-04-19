# AliceChat Architecture

## Product direction

AliceChat is a cross-platform client for OpenClaw, but development starts on Android.
Windows support should reuse the same application core as much as possible.

## Why Flutter + Flyer Chat

### Flutter
- one codebase for Android and Windows
- mature ecosystem for realtime apps
- good UI velocity for mobile-first work

### Flyer Chat
- polished chat primitives out of the box
- backend-agnostic
- suitable for assistant, human, and mixed system messages
- customizable enough for OpenClaw-specific UX later

## MVP architecture

```text
UI (Flyer Chat)
  ↓
Chat Feature Layer
  ↓
OpenClaw Client Abstraction
  ├─ HTTP API client
  ├─ WebSocket stream client
  └─ Local storage adapter
```

## Core modules

### 1. app/
Global app shell, theme, route wiring.

### 2. features/chat/
- chat screen
- message mapping between OpenClaw payloads and Flyer Chat message models
- send/retry/state logic

### 3. features/settings/
- server URL
- auth token or future login material
- connection test

### 4. core/openclaw/
- OpenClaw REST client
- OpenClaw WebSocket client
- DTOs and mapping helpers

## Message model strategy

Use internal domain models first, then map to Flyer Chat models.
This prevents UI package lock-in from leaking into transport code.

Recommended domain entities:
- ChatSession
- ChatMessage
- AttachmentRef
- StreamEvent

## Android-first scope

### Must have now
- text chat
- assistant streaming output
- reconnect behavior
- basic settings persistence

### Defer
- voice
- file upload
- image generation rendering
- multi-account support
- Windows packaging polish

## Recommended first delivery milestone

### Milestone A: clickable shell
- app boots on Android
- mock chat with Flyer Chat renders
- settings page exists

### Milestone B: real backend
- connect to OpenClaw endpoint
- load history
- send message
- receive assistant response

### Milestone C: stable mobile base
- persistence
- error UI
- reconnects
- session switching

## Suggested backend contract adapter

Because OpenClaw deployments may differ, create a thin adapter layer that can normalize:
- session list endpoints
- message history endpoints
- stream/event endpoints
- auth headers

That adapter should be the only layer aware of raw wire format.
