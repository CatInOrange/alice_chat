# OpenClaw Live2D Channel Bridge

This plugin adds a `live2d` channel to OpenClaw.

## Intended architecture

- Live2D frontend <-> Python backend: keep existing HTTP / SSE flow
- Python backend <-> OpenClaw: use this channel over WebSocket
- Goal: replace the old direct Gateway session websocket from Python

## Bridge protocol

Python backend connects to:

- `ws://127.0.0.1:18790` by default

Frame sent by Python backend:

```json
{
  "type": "chat.request",
  "requestId": "uuid",
  "text": "你好",
  "attachments": [
    {
      "kind": "image",
      "content": "<base64>",
      "mimeType": "image/png"
    }
  ],
  "agent": "live2d",
  "session": "main",
  "sessionKey": "agent:live2d:main",
  "senderId": "desktop-user",
  "senderName": "Live2D User",
  "conversationLabel": "main"
}
```

Frames returned by OpenClaw channel:

- `chat.accepted`
- `chat.typing`
- `chat.delta`
- `chat.media`
- `chat.final`
- `chat.error`

## Install locally

```bash
openclaw plugins install /absolute/path/to/openclaw-channel-live2d
openclaw plugins enable live2d
```

## OpenClaw config

Add to `~/.openclaw/openclaw.json`:

```json5
{
  channels: {
    live2d: {
      enabled: true,
      websocketHost: "127.0.0.1",
      websocketPort: 18790,
    },
  },
}
```

Then restart gateway:

```bash
openclaw gateway restart
```

## Lunaria provider config

Use provider type `openclaw-channel` in `config.json`:

```json5
{
  "id": "live2d-channel",
  "type": "openclaw-channel",
  "name": "OpenClaw Live2D Channel",
  "bridgeUrl": "ws://127.0.0.1:18790",
  "agent": "live2d",
  "session": "main"
}
```
