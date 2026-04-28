# AliceChat Notification Refactor Implementation Mapping

## Status
- Proposed
- Depends on:
  - `docs/notification-architecture-refactor.md`
  - `docs/notification-implementation-plan.md`

## Purpose

This document maps the approved notification refactor architecture onto the current AliceChat codebase.

It answers four practical questions:
1. where notification-related behavior lives today
2. which parts should remain and be evolved
3. which parts should be narrowed, replaced, or deleted
4. what the migration boundaries are at file/class level

This is a code-oriented companion to the architecture spec and implementation plan.

---

# 1. Current code map

## 1.1 Backend event delivery path

### A. `backend/app/routes/events.py`
**Current role**
- exposes `GET /api/events`
- replays historical events via `since`
- subscribes to live events from `events_bus`
- sends both replay and live events over SSE
- already audits replay/live internally via `phase='events_route_replay'` and `phase='events_route_live'`

**Why it matters**
- this is the exact stream layer where replay vs live is already known
- phase knowledge exists here, but is not yet surfaced as first-class notification semantics to clients

**Refactor disposition**
- **keep and evolve**

**Expected changes**
- include explicit `delivery_phase` in outgoing event payloads or envelopes
- preserve current `since`/resume behavior
- do not move notification decisioning here
- make this layer the authoritative source of replay/live labeling

---

### B. `backend/app/services/events_bus.py`
**Current role**
- publishes events into the event bus
- stores them in SQLite-backed `EventStore`
- fans out live events to subscribers
- supports resumable delivery semantics

**Why it matters**
- this is the persistence/fan-out substrate for replay correctness
- notification refactor depends on this remaining resumable and monotonic

**Refactor disposition**
- **keep**

**Expected changes**
- likely little or no business logic change
- may need small DTO/envelope evolution if `delivery_phase` is attached here or passed through more cleanly
- should remain transport substrate, not notification policy layer

---

### C. `backend/app/routes/chat.py`
**Current role**
- persists user message
- emits `message.created`, `message.status`, `assistant.message.started`, `assistant.progress`, `assistant.message.completed`, `assistant.message.failed`
- currently triggers `context.push_service.notify_new_message(...)` after assistant completion

**Why it matters**
- this is one of the main message-finalization paths
- this is the most likely place where notification-candidate business intent can be defined

**Refactor disposition**
- **keep but restructure notification emission responsibility**

**Expected changes**
- define explicit backend-side emission of `notification.candidate`
- stop relying on downstream clients to infer notification intent from `assistant.message.completed`
- keep chat/UI event emissions for UI consumers
- ensure `notification.candidate` is emitted only when stable `sessionId/messageId` exist
- likely narrow or re-evaluate the current `push_service.notify_new_message(...)` role so the architecture remains coherent

**Important note**
- this file currently mixes chat completion flow and push-trigger-like behavior
- that is workable short-term, but candidate-event creation should become an explicit local responsibility, not an incidental side effect buried after completion

---

### D. `backend/app/services/chat_streaming.py`
**Current role**
- emits intermediate payloads
- contributes to `message.created` emission path

**Why it matters**
- it is part of the broader chat event ecosystem
- but it is not the right home for final notification decisioning

**Refactor disposition**
- **keep, but do not turn into notification policy logic**

**Expected changes**
- likely none beyond preserving clean upstream data for final message events

---

### E. `backend/app/agents/openclaw_channel.py`
**Current role**
- adapts upstream OpenClaw frames into local progress/final semantics
- handles `chat.progress`, `chat.final`, etc.

**Why it matters**
- rich upstream frame shapes currently influence what downstream sees
- notification refactor should reduce the need for device-side guessing from this layer's output

**Refactor disposition**
- **keep**

**Expected changes**
- probably none for phase 1 unless candidate semantics need a cleaner hook upstream
- notification engine should not directly depend on this file's progress heuristics

---

## 1.2 Android native notification path

### A. `android/app/src/main/kotlin/com/example/alice_chat/AliceChatForegroundService.kt`
**Current role**
- maintains Android foreground service
- directly connects to `/api/events`
- uses `?since=` replay resume
- parses SSE manually
- filters for `assistant.message.completed` and `message.created`
- applies local suppression logic using `activeSessionId` and `appForeground`
- builds and posts Android notifications
- currently computes notification id from `(eventSessionId + messageId + teaser).hashCode()`

**Why it matters**
- this is already the de facto native notification engine, but it is too broad and too heuristic
- it is the primary target for refactor into the formal single notification authority

**Refactor disposition**
- **keep, but heavily refactor internally**

**Expected changes**
- split into explicit subcomponents:
  - `NotificationCandidateConsumer`
  - `NotificationDecisionEngine`
  - `NotificationRenderer`
  - `NotificationDedupeStore`
  - `NotificationAuditLogger`
  - `NotificationRuntimeState`
- stop using generic `assistant.message.completed` / `message.created` as direct notification triggers
- consume only `notification.candidate`
- treat replay vs live explicitly
- remove teaser-based notification identity
- retain foreground-service shell and stream-lifecycle responsibilities

**Specific problematic responsibilities today**
- business intent inference from generic events
- replay/live blindness
- suppression logic embedded inline with parsing and rendering
- notification id polluted by teaser
- `recentlyBackgrounded` heuristic living in the main service logic rather than a cleaner policy model

---

### B. `android/app/src/main/kotlin/com/example/alice_chat/MainActivity.kt`
**Current role**
- exposes method channel entrypoints:
  - `startForegroundService`
  - `stopForegroundService`
  - `updateActiveSession`
  - `updateSessionMetadata`
  - `updateAppForeground`
- captures notification open intents and stores pending payload for Flutter to consume

**Why it matters**
- this is the bridge ingress between Flutter and native notification runtime

**Refactor disposition**
- **keep, but narrow and formalize bridge contract**

**Expected changes**
- replace multiple ad hoc runtime-updating calls with a more coherent bridge contract where possible
- preserve notification-open capture path
- keep notification-open routing separate from notification send policy

---

### C. `android/app/src/main/kotlin/com/example/alice_chat/AliceChatBootReceiver.kt`
**Current role**
- starts foreground service on boot

**Why it matters**
- affects service persistence/restart scenarios

**Refactor disposition**
- **keep**

**Expected changes**
- likely none beyond ensuring service restart behavior works with persisted dedupe/cursor state

---

## 1.3 Flutter-side notification and lifecycle path

### A. `lib/features/notifications/application/notification_service.dart`
**Current role**
- initializes `flutter_local_notifications`
- tracks `_activeSessionId`
- tracks `_isAppForeground`
- reports presence
- binds session to contact metadata
- directly calls `showChatNotification(...)`
- suppresses notifications based on active session / foreground flags
- computes notification id using `sessionId ^ messageId ^ teaser`

**Why it matters**
- this is currently both:
  - a metadata/presence service
  - a final notification sender
- that split is one of the biggest architectural problems

**Refactor disposition**
- **keep partially, narrow aggressively**

**Keep responsibilities**
- contact/session metadata registry
- notification-open stream handling for Flutter-local notifications if still needed in other contexts
- presence reporting if still product-relevant

**Remove or deprecate responsibilities**
- Android final system-notification sending for chat notifications
- active-session suppression policy as a final notification decision
- teaser-based notification identity

**Expected changes**
- `showChatNotification(...)` should be removed from the Android chat-notification authority path
- this class should no longer be a competing final sender for Android chat message notifications
- if Flutter-local notification support remains for non-Android or non-chat cases, separate those concerns clearly

---

### B. `lib/features/notifications/application/background_connection_service.dart`
**Current role**
- manages method-channel communication for background service start/stop/update
- stores `_activeSessionId` and `_appForeground`
- mirrors lifecycle changes into native service
- updates session metadata
- consumes pending notification-open payload

**Why it matters**
- this is currently one of the key duplicated state holders
- it is close to what the future runtime-state bridge should become

**Refactor disposition**
- **keep, but refactor into a coherent runtime-state bridge**

**Expected changes**
- replace scattered state update methods with a more explicit runtime-state synchronization model
- reduce internal duplication of appForeground/activeSession knowledge that is also held elsewhere
- remain the main Flutter-side gateway to native runtime state

**What it should become**
- primary Flutter → native notification runtime bridge
- session metadata synchronizer
- pending-notification-open consumer

**What it should stop being**
- a loose bag of unrelated foreground-service commands without a formal state contract

---

### C. `lib/app/app.dart`
**Current role**
- app lifecycle observer
- sets app foreground in both `NotificationService` and `BackgroundConnectionService`
- keeps active chat session tracking
- syncs active session to notification services
- clears active-session bindings on close/background
- consumes pending notification opens on launch/resume

**Why it matters**
- this file contains much of the real lifecycle choreography
- it is currently orchestrating multiple state sinks at once

**Refactor disposition**
- **keep orchestration role, but simplify outputs**

**Expected changes**
- app lifecycle should feed one coherent state bridge, not multiple competing notification-state stores
- active-session changes should flow through one reducer/synchronization path
- root-back/background logic should stop manually coordinating multiple loosely related flags where avoidable

**Current fragility hotspots**
- `didChangeAppLifecycleState(...)` updating multiple services independently
- `_prepareForBackgroundTransition(...)` and `_clearActiveSessionBindings(...)`
- `_syncActiveSessionFromStore(...)` writing to both `NotificationService` and `BackgroundConnectionService`

---

### D. `lib/features/chat/application/chat_session_store.dart`
**Current role**
- subscribes to `/api/events` with `since: state.lastEventSeq`
- handles UI-facing events such as `message.created`, `assistant.progress`, `assistant.message.completed`

**Why it matters**
- this is the main chat UI replay/live consumer on Flutter side
- it should remain a UI consumer, not a hidden notification authority

**Refactor disposition**
- **keep**

**Expected changes**
- likely minimal for notification phase 1
- do not let this file become a source of Android system-notification decisioning
- may later consume richer semantic events for in-app indication, but not as final notification authority

---

### E. `lib/core/openclaw/openclaw_http_client.dart`
**Current role**
- constructs `/api/events` subscription on Flutter side

**Why it matters**
- may need small DTO evolution if event payloads gain explicit `delivery_phase` and `notification.candidate`

**Refactor disposition**
- **keep**

**Expected changes**
- mostly pass-through compatibility updates if event shapes evolve

---

# 2. Target ownership after refactor

## Backend
### Owns
- notification candidate creation
- replay/live labeling
- stable event identity
- event resume semantics

### Does not own
- final device-side show/suppress decision
- Android-specific dedupe/rendering policy

## Android native
### Owns
- final Android chat-notification decision
- dedupe
- replay suppression on device
- notification rendering
- device-side audit logs
- notification cursor consumption for candidate events

### Does not own
- business inference from generic chat progress events
- duplicated policy mirrored in Flutter

## Flutter
### Owns
- lifecycle observation
- active chat session determination
- runtime-state reporting to native
- metadata mapping for sessions/contacts
- notification tap navigation
- chat UI event consumption

### Does not own
- final Android chat-notification emission policy

---

# 3. Migration mapping by file

## 3.1 Backend migration tasks

### `backend/app/routes/events.py`
**Action**
- evolve SSE payload model to expose `delivery_phase`

**Notes**
- this is likely the least risky place to attach replay/live semantics because the route already knows which branch emitted each event

### `backend/app/routes/chat.py`
**Action**
- add explicit `notification.candidate` emission near assistant completion / inbound message finalization points

**Notes**
- likely create helper(s) so candidate construction is not duplicated
- do not bury candidate semantics in UI-only progress emission paths

### `backend/app/services/events_bus.py`
**Action**
- preserve monotonic sequence/store semantics
- only touch if envelope/persistence format needs tiny evolution

**Notes**
- avoid embedding policy here

---

## 3.2 Android migration tasks

### `AliceChatForegroundService.kt`
**Action**
- refactor into explicit internal modules/classes
- consume `notification.candidate` only
- add decision engine + dedupe + audit logger

**Likely extracted pieces**
- `NotificationCandidateParser`
- `NotificationRuntimeState`
- `NotificationDecisionEngine`
- `NotificationDedupeStore`
- `NotificationRenderer`
- `NotificationAuditLogger`

**Delete/replace**
- inline heuristic filtering on `assistant.message.completed` / `message.created`
- teaser-based notification id
- implicit replay-as-live behavior

### `MainActivity.kt`
**Action**
- keep bridge and notification-open capture
- simplify method-channel surface toward coherent runtime-state updates

---

## 3.3 Flutter migration tasks

### `notification_service.dart`
**Action**
- narrow to metadata/presence/open handling roles
- remove Android final-send responsibility for chat notifications

**Delete/replace**
- `showChatNotification(...)` as the Android chat-notification final path
- suppression-as-final-policy logic for Android chat notifications
- teaser-based notification id logic

### `background_connection_service.dart`
**Action**
- promote into the primary runtime-state bridge
- formalize state update contract

**Keep**
- service start/stop if still required
- session metadata synchronization
- pending notification-open consumption

**Refactor**
- scattered flag mutation into coherent state sync

### `app.dart`
**Action**
- reduce multi-sink lifecycle writes
- route lifecycle and active-session changes through one bridge path

**Delete/replace**
- duplicated foreground writes to multiple notification-state owners where no longer needed

---

# 4. High-risk coupling points to address explicitly

## 4.1 Competing senders
**Today**
- Flutter `NotificationService` can send notifications
- Android foreground service can send notifications

**Required outcome**
- only Android native remains the final sender for Android chat notifications

---

## 4.2 Split runtime state
**Today**
- app foreground and active session are tracked in multiple places:
  - `NotificationService`
  - `BackgroundConnectionService`
  - `AliceChatForegroundService`
  - app lifecycle orchestration in `app.dart`

**Required outcome**
- Flutter assembles one coherent state snapshot
- native stores one coherent runtime state

---

## 4.3 Replay blindness
**Today**
- backend route knows replay vs live
- native foreground service does not treat this as a first-class notification decision input

**Required outcome**
- replay/live must be explicit end-to-end for notification candidates

---

## 4.4 Dedupe instability
**Today**
- both Flutter and native chat-notification paths use teaser in notification identity

**Required outcome**
- dedupe and notification id use stable business identity only

---

# 5. Recommended implementation order in code terms

## Step A - backend semantics first
Touch first:
- `backend/app/routes/events.py`
- `backend/app/routes/chat.py`

Goal:
- candidate events exist
- delivery phase exists

## Step B - native decision engine skeleton
Touch next:
- `AliceChatForegroundService.kt`
- potentially new Kotlin helper files under a notification package

Goal:
- native can parse candidate events
- native writes audit logs
- native suppresses replay

## Step C - native dedupe + stable rendering identity
Touch next:
- native notification posting logic
- native persistent store

Goal:
- one live background candidate => one visible notification
- replay and reconnect do not duplicate

## Step D - Flutter bridge cleanup
Touch next:
- `background_connection_service.dart`
- `app.dart`
- `notification_service.dart`

Goal:
- state updates stop being split-brain
- active-session suppression becomes deterministic

## Step E - competing sender removal
Touch last:
- final Android chat-notification send paths in Flutter

Goal:
- one final sender remains

---

# 6. Deletion/deprecation candidates

## High-confidence candidates
- teaser-based notification id generation in Flutter
- teaser-based notification id generation in native Android service
- direct notification inference from generic `assistant.message.completed` / `message.created` in native service once candidates exist
- Flutter as final Android chat-notification sender once migration is complete

## Moderate-confidence candidates
- duplicated foreground/session updates spread across multiple APIs, after unified bridge lands
- `recentlyBackgrounded` heuristic in its current ad hoc form, once policy is formalized cleanly

---

# 7. Concrete questions answered by this mapping

## Where should `notification.candidate` be emitted?
Recommended answer:
- in backend message-finalization paths centered around `backend/app/routes/chat.py`
- not in Flutter
- not inferred only inside Android client

## Where should `delivery_phase` come from?
Recommended answer:
- from the SSE delivery layer in `backend/app/routes/events.py`
- because replay/live is already known there

## What should become the Android notification engine?
Recommended answer:
- refactored `AliceChatForegroundService.kt`
- not a brand new parallel service unless current service proves structurally impossible to clean up

## What should be the Flutter runtime-state bridge?
Recommended answer:
- evolve `BackgroundConnectionService`
- simplify `app.dart` to feed it coherently
- reduce `NotificationService` to metadata/presence/open-handling concerns

---

# 8. Implementation readiness checklist

Ready to start code when all are true:
- backend candidate emission point is agreed
- delivery-phase exposure shape is agreed
- native notification module boundary is agreed
- Flutter competing final-send path is identified and marked for deprecation
- runtime-state bridge target contract is agreed

## Summary

The current codebase already contains the pieces needed for a clean notification architecture, but they are distributed and overlapping.

The refactor should not replace everything blindly.
It should:
- preserve the resumable backend stream substrate
- preserve the Android foreground-service shell
- preserve Flutter lifecycle and navigation orchestration
- but reassign responsibilities cleanly so that notification behavior becomes explicit, singular, and testable.