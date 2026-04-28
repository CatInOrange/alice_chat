# AliceChat Notification Architecture Refactor Spec

## Status
- Proposed
- Target: Android-first implementation, with cross-platform-compatible semantics where practical

## Goals

This refactor replaces the current patch-style notification behavior with a single, explicit, testable architecture.

The new design must be:
- robust under foreground/background transitions
- explicit about replay vs live delivery
- resistant to duplicate notifications
- resistant to missed notifications caused by lifecycle races
- easy to reason about from logs alone
- modular enough to evolve without reintroducing split-brain state

## Non-goals

This spec does not attempt to:
- redesign the entire chat event protocol for all product areas
- define iOS implementation details yet
- solve every product-level notification preference in the first pass
- remove replay from the event system; replay remains important for consistency

## Problems in the current design

The current mobile notification path has several architectural weaknesses:

1. **Decision authority is split across layers**
   - Flutter notification logic
   - Android foreground service logic
   - app lifecycle wiring
   - chat subscription state

2. **Notification behavior is inferred from generic chat events**
   - notification logic is downstream of a broad event stream
   - replay, progress, message completion, and UI-facing events are mixed together

3. **Replay and live events are not first-class distinct concepts for notification delivery**
   - this makes historical catch-up capable of producing fresh notifications

4. **Foreground/background and active-session state are duplicated and synchronized loosely**
   - this introduces race conditions
   - behavior near app transitions becomes non-deterministic

5. **Dedupe identity is not purely business-stable**
   - notification identity must not depend on decorative text or random teaser variants

6. **Observability is insufficiently structured**
   - when a notification is missed or duplicated, root cause is not obvious from one audit trail

## Design principles

### 1. Single notification authority
Only one runtime component is allowed to make the final system-notification decision on Android.

**Decision:** Android native notification engine is the single final authority.

Flutter may:
- report app state
- report active session context
- provide routing metadata
- react to notification taps

Flutter must not independently make final system-notification send decisions once the refactor is complete.

### 2. Explicit delivery phases
Every event used for notification must carry an explicit delivery phase:
- `replay`
- `live`

Rules:
- `replay` may repair state and advance cursors
- `replay` must not emit a user-visible system notification
- `live` may be eligible for system notification

### 3. Stable business identity
Notification dedupe must be based on stable business identifiers only.

At minimum:
- `session_id`
- `message_id`

Never use:
- random teaser text
- localized preview body
- formatted timestamps
- transient UI strings

### 4. State machine over scattered flags
Foreground/background status and active-session suppression must be modeled as a coherent runtime state machine, not as multiple loosely synchronized booleans.

### 5. UI events and notification events are different products
The chat UI needs rich transport semantics.
The notification layer needs a narrow, trustworthy candidate stream.

The notification engine must not guess user-visible notification intent from arbitrary chat-progress events.

### 6. Auditability by construction
Each notification candidate must produce a structured decision record, whether it results in a visible notification or not.

## Target architecture

```text
Backend Event Source
  ├─ Chat event stream (UI-oriented)
  └─ Notification candidate semantics
              ↓
Android Notification Engine (single authority)
  ├─ Delivery-phase handling
  ├─ Dedupe
  ├─ Suppression policy
  ├─ Notification rendering
  └─ Structured audit log

Flutter App
  ├─ App lifecycle reporting
  ├─ Active-session reporting
  ├─ Session metadata cache
  └─ Notification tap routing
```

## Core components

## 1. Notification Candidate Event

Introduce an explicit event shape for notification evaluation.

Example shape:

```json
{
  "kind": "notification.candidate",
  "event_id": "evt_123",
  "seq": 10452,
  "delivery_phase": "live",
  "session_id": "sess_abc",
  "message_id": "msg_def",
  "message_kind": "assistant_reply",
  "sender_id": "assistant",
  "title": "AliceChat",
  "body_preview": "...",
  "dedupe_key": "sess_abc:msg_def",
  "created_at": "2026-04-28T15:01:02Z",
  "routing": {
    "conversation_type": "direct"
  }
}
```

### Required fields
- `kind`
- `event_id`
- `seq`
- `delivery_phase`
- `session_id`
- `message_id`
- `message_kind`
- `dedupe_key`
- `created_at`

### Optional fields
- `title`
- `body_preview`
- `sender_id`
- `routing`
- future product-specific notification hints

### Constraints
- `event_id` must be globally unique
- `seq` must be monotonic within the stream contract used by the client
- `dedupe_key` must be stable for the same logical message
- `delivery_phase` must be emitted by the backend, not guessed client-side

## 2. Notification Runtime State

The Android notification engine should own one coherent state object.

Example:

```kotlin
data class NotificationRuntimeState(
  val appForeground: Boolean,
  val activeSessionId: String?,
  val notificationsEnabled: Boolean,
  val streamConnected: Boolean,
  val lastSeenSeq: Long?,
  val lastForegroundAtMs: Long?,
  val lastBackgroundAtMs: Long?,
  val appProcessState: AppProcessState
)
```

### AppProcessState
Suggested enum:
- `FOREGROUND_INTERACTIVE`
- `FOREGROUND_NON_CHAT`
- `BACKGROUND`
- `TERMINATING`

This does not need to mirror Android APIs one-to-one. It should represent notification policy states.

## 3. Notification Decision Engine

Introduce a dedicated decision engine on Android native side.

Inputs:
- notification candidate event
- current `NotificationRuntimeState`
- notification settings
- dedupe store

Outputs:
- decision result
- optional rendered notification payload
- structured audit record

Example decision enum:
- `SHOW`
- `SUPPRESS_REPLAY`
- `SUPPRESS_FOREGROUND_ACTIVE_SESSION`
- `SUPPRESS_DISABLED`
- `SUPPRESS_DUPLICATE`
- `DROP_INVALID`
- `DROP_STALE`

### Rule order
Decision order should be explicit and stable.

Recommended order:
1. validate event shape
2. validate delivery ordering assumptions
3. suppress replay
4. suppress disabled notifications
5. suppress duplicate
6. suppress foreground active-session case
7. apply stale-event policy if needed
8. show notification

This order must be documented in code and tests.

## 4. Dedupe Store

The notification engine needs a stable dedupe mechanism.

### Required behavior
- dedupe by `dedupe_key`
- do not depend on teaser/body/title variants
- preserve enough history to avoid duplicate sends across reconnects and short process restarts

### Recommended storage
- lightweight persistent store on device
- bounded retention window

### Suggested retention model
Keep a rolling set of recently delivered `dedupe_key`s, such as:
- N most recent keys, or
- keys within last X hours

The exact retention limit can be tuned, but the mechanism must survive transient disconnects and foreground-service restarts.

## 5. Audit Log

Every notification candidate must yield a structured audit entry.

Example audit fields:
- `event_id`
- `seq`
- `delivery_phase`
- `session_id`
- `message_id`
- `dedupe_key`
- `decision`
- `reason`
- `app_foreground`
- `active_session_id`
- `notification_id`
- `shown`
- `failed`
- `timestamp`

This log should answer, with no guesswork:
- why a notification was shown
- why it was suppressed
- whether it came from replay or live delivery
- whether it was considered duplicate

## Stream model

## Recommended near-term approach

Keep the existing broad event transport if needed, but ensure that the notification engine only evaluates explicit `notification.candidate` events.

That means:
- UI keeps using the broader event set
- notification engine ignores generic progress/delta/final events unless the backend emits a notification candidate semantic event

## Longer-term optional evolution

If later useful, split notification delivery into a dedicated stream such as:
- `/api/notifications/stream`

This is not required for phase 1 if semantic separation is already clean.

## Foreground/background policy

## Definitions

### Active session
The session currently open and visible to the user as the focused chat surface.

### Foreground
The app is interactive and visible to the user.

### Background
The app is not the foreground interactive surface, regardless of whether a foreground service remains alive.

## Policy matrix

### Case A: app foreground + active session equals event session
Decision: suppress system notification.

Reason:
- the user is already looking at the conversation
- the UI can handle the live update directly

### Case B: app foreground + active session different from event session
Decision: product choice, but default should be either:
- show a lighter notification, or
- defer to in-app indicator only

For phase 1, choose one explicitly and document it. Do not leave this ambiguous.

### Case C: app background
Decision: eligible for system notification if live and non-duplicate.

### Case D: replay after reconnect
Decision: never show system notification, regardless of foreground/background.

## Transition behavior

Foreground/background transitions must not rely on scattered fire-and-forget updates.

Required properties:
- transition events flow through one bridge into one state reducer
- active-session updates have defined ordering relative to lifecycle state transitions
- state writes are idempotent
- old/out-of-order updates are ignored safely

## Ordering requirements

For example, when leaving a chat screen and backgrounding:
1. update active-session state intentionally
2. update app process state intentionally
3. flush to native state bridge
4. only then rely on notification suppression policy derived from the new state

The exact event order may differ in implementation, but it must be deterministic and documented.

## Edge cases and required behavior

## 1. Replay burst after reconnect
Scenario:
- app/service disconnects
- many events accumulate
- connection resumes with `since=lastSeenSeq`

Required behavior:
- consume replay
- advance cursor
- do not emit notifications for replay items
- only begin visible notification delivery once live phase resumes

## 2. App backgrounds while reply is in-flight
Scenario:
- user sends a message in foreground
- app backgrounds before assistant reply completes

Required behavior:
- if completion arrives in `live` phase while app is backgrounded, notification is eligible
- if completion is only later obtained via replay, it must not notify retroactively as new

This prevents ambiguous “sometimes notified, sometimes batch-flushed later” behavior.

## 3. Foreground-service restart
Scenario:
- Android kills/restarts the foreground service
- service resumes with persisted cursor

Required behavior:
- dedupe store survives restart
- replay resumes from last cursor
- replay does not show notifications

## 4. Rapid session switching
Scenario:
- user switches sessions quickly
- state bridge sends multiple active-session updates close together

Required behavior:
- last accepted state wins deterministically
- notification engine never uses decorative timing guesses
- suppression logic reflects final coherent state, not transient intermediate fragments

## 5. Notification tap race
Scenario:
- user taps a notification while replay or another active update is in progress

Required behavior:
- route by stable `session_id` and `message_id`
- routing should be idempotent
- notification open handling must not create duplicate chat sessions or duplicate event subscriptions

## 6. Duplicate logical event with variant preview text
Scenario:
- same message arrives with changed preview/teaser text

Required behavior:
- treated as same logical notification if `dedupe_key` is the same
- may update an existing notification presentation if desired
- must not create a second notification entry solely due to text variation

## 7. Delayed stale event
Scenario:
- a live event arrives far later than expected due to transport lag or server retry

Required behavior:
- define stale threshold policy explicitly
- either still show because it is logically new, or suppress as stale
- do not leave this behavior accidental

For phase 1, the simplest professional stance is:
- replay is suppressed by phase
- live events are still treated as eligible unless product defines a stale-age threshold

## 8. App foreground but not in chat UI
Scenario:
- app open on settings or another screen
- relevant assistant reply arrives

Required behavior:
- explicit product choice required
- recommended default: show notification or at least in-app surface distinct from active-chat suppression

Do not silently treat all app-foreground states as equivalent.

## Backend responsibilities

The backend must:
- emit explicit notification candidate semantics
- label delivery phase correctly
- preserve stable identifiers
- support resume via `seq` / `since`
- avoid requiring the client to infer notification intent from UI-only events

The backend should not assume:
- the client can infer replay/live reliably by timing
- the client knows whether a completion event is a user-facing notification candidate without semantic labeling

## Flutter responsibilities after refactor

Flutter should:
- report lifecycle transitions through one bridge
- report active chat session through one bridge
- maintain UI subscriptions for chat rendering
- react to notification taps and navigate accordingly

Flutter should not:
- independently decide final Android system-notification sends
- create competing dedupe behavior separate from native notification engine
- use notification policy hacks to compensate for chat-stream semantics

## Android responsibilities after refactor

Android native notification engine should:
- own stream consumption for notification candidates
- own cursor advancement for notification delivery
- own dedupe
- own final decisioning
- own audit logging
- own system notification rendering

## Migration plan

## Phase 1: semantic cleanup without product-surface churn
1. add `notification.candidate` semantics on backend
2. add `delivery_phase`
3. add native decision engine skeleton
4. move dedupe to stable business key
5. ensure replay suppression
6. add structured audit logs
7. stop Flutter from being a competing final sender

## Phase 2: state-model cleanup
1. introduce unified runtime state bridge
2. remove scattered foreground/background flag updates
3. formalize active-session update ordering
4. simplify suppress rules around current-session behavior

## Phase 3: product-level polish
1. notification grouping by session
2. richer priority and channel strategy
3. per-user policy preferences
4. optional dedicated notification stream

## Testing strategy

## Unit tests

### NotificationDecisionEngine
Test all decision branches:
- invalid event
- replay suppression
- duplicate suppression
- foreground active-session suppression
- background live show
- settings disabled suppression

### Dedupe store
Test:
- same dedupe key with different preview text
- dedupe persistence across restart
- retention expiry behavior

### Runtime state reducer
Test:
- foreground/background transitions
- rapid active-session updates
- stale state updates
- idempotent repeated updates

## Integration tests

### Replay scenario
- receive live events
- disconnect
- accumulate server events
- reconnect with `since`
- verify replay updates cursor only
- verify no replay notifications shown

### Background reply scenario
- send message in foreground
- background app
- assistant reply arrives live
- verify exactly one notification

### Current-session suppression scenario
- keep session open in foreground
- assistant reply arrives live
- verify no system notification

### Session-switch scenario
- switch from session A to B rapidly
- reply arrives for A and B
- verify deterministic suppression/show behavior

### Service restart scenario
- persist cursor and dedupe state
- restart service
- replay resumes
- verify no duplicate notifications

## Observability acceptance criteria

A single notification audit trail must be enough to explain each candidate.

For any given `message_id`, engineering must be able to answer:
- did it reach the device?
- was it replay or live?
- was it suppressed?
- if suppressed, exactly why?
- if shown, under which notification id?
- did rendering fail?

## Rollout guidance

Use a guarded rollout.

Recommended steps:
1. ship audit logging first if safe
2. ship semantic separation and replay suppression behind a flag if needed
3. monitor duplicate/missed-notification metrics from audit logs
4. remove old competing notification paths only after the new path is verified stable

## Risks and mitigations

### Risk: partial migration causes two senders to remain active
Mitigation:
- enforce one final sender by config/flag during rollout
- add startup assertion/log if multiple send paths are enabled

### Risk: backend emits incomplete candidate semantics
Mitigation:
- validate event shape strictly
- drop invalid candidates with explicit audit reason
- do not silently guess missing fields

### Risk: lifecycle bridge remains noisy
Mitigation:
- reducer-based state normalization
- monotonic sequence or timestamp guard on state updates if needed

### Risk: product ambiguity on foreground non-active-session behavior
Mitigation:
- choose a documented default before implementation begins
- test it explicitly

## Open decisions before implementation

These decisions must be finalized before coding starts:

1. When app is foreground but user is not inside the event session, should phase-1 behavior be:
   - visible system notification, or
   - in-app indicator only?

2. Should the notification engine read from:
   - the existing general event stream with semantic filtering, or
   - a dedicated notification stream now?

3. What retention window should the dedupe store use?

4. Should stale live events still notify, or should there be an age threshold?

## Recommended defaults

To keep the implementation clean and low-risk, recommended defaults are:
- foreground + active session: suppress system notification
- foreground + different screen/session: show notification in phase 1
- background: show notification if live and non-duplicate
- replay: never show notification
- dedupe retention: at least enough to cover reconnects and short service restarts
- stale policy: no extra stale suppression in phase 1 unless product requires it

## Definition of done

The refactor is complete only when all are true:

1. Android has one final notification decision engine
2. replay and live are explicitly distinguished end-to-end
3. notification dedupe uses only stable business identity
4. current-session suppression is deterministic and tested
5. duplicate notification regressions are covered by automated tests
6. missed-notification diagnosis is possible from structured logs alone
7. Flutter no longer acts as a competing final sender for Android system notifications

## Summary

This refactor moves AliceChat notifications from a fragile, distributed, inference-heavy setup to a single-authority, state-machine-based, semantically explicit design.

The key architectural shift is simple:
- **notification intent becomes explicit**
- **delivery phase becomes explicit**
- **decision authority becomes singular**
- **state becomes coherent**
- **dedupe becomes stable**
- **logs become decisive**

That is the minimum standard for a mature and robust notification system.