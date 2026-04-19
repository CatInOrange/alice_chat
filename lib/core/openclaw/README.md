# OpenClaw adapter layer

This folder is the boundary between AliceChat and raw OpenClaw APIs.

Keep these rules:
- UI should not depend on raw wire payloads.
- Normalize transport responses into domain models.
- Keep auth/header handling here.
- Support both REST history loading and WebSocket or SSE streaming here.

Suggested next files:
- `openclaw_models.dart`
- `openclaw_mapper.dart`
- `openclaw_ws_client.dart`
- `openclaw_session_repository.dart`
