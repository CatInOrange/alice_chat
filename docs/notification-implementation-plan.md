# AliceChat Notification Refactor Implementation Plan

## Status
- Proposed
- Depends on: `docs/notification-architecture-refactor.md`

## Objective

This document translates the notification architecture refactor spec into an execution plan.

The goal is to move from the current mixed, patch-style notification behavior to a mature implementation with:
- one Android final sender
- explicit notification semantics
- explicit replay/live handling
- deterministic current-session suppression
- stable dedupe
- structured auditability

## Approved product decisions

The following decisions are already accepted for phase 1:

1. **App foreground but not inside the event session**
   - show a system notification

2. **Transport direction for phase 1**
   - keep the existing general event stream
   - add semantic separation via `notification.candidate`
   - do not build a dedicated notification stream yet

3. **Dedupe retention direction**
   - retain enough delivered keys to cover reconnects and foreground-service restarts
   - implementation may use a bounded time window or bounded recent-key set

## Execution strategy

The work should be delivered in ordered phases.

Do not begin cleanup of old logic before the new path is able to:
- consume candidate events
- suppress replay
- emit audit logs
- produce one visible Android notification under normal background delivery

## Workstreams

The implementation is divided into five workstreams:

1. backend notification semantics
2. Android native notification engine
3. Flutter-to-native state bridge cleanup
4. migration/removal of competing paths
5. validation and test coverage

---

# Phase 0 - Implementation guardrails

## Purpose
Set hard boundaries before code changes spread.

## Tasks

### 0.1 Freeze target architecture in docs
- keep `notification-architecture-refactor.md` as the source-of-truth architecture spec
- use this plan as the source-of-truth sequencing doc

### 0.2 Define rollout flags
Introduce feature flags or config toggles for:
- `notificationCandidateEventsEnabled`
- `nativeNotificationDecisionEngineEnabled`
- `flutterFinalNotificationSendEnabled`
- `notificationAuditLoggingEnabled`

### 0.3 Add startup assertions
At runtime, log and optionally assert if both are true simultaneously in non-migration mode:
- native final sender enabled
- Flutter final sender enabled

### 0.4 Establish logging correlation ids
Make sure notification-related logs can correlate at least:
- `event_id`
- `seq`
- `session_id`
- `message_id`
- `dedupe_key`

## Exit criteria
- flags exist or are at least concretely defined in implementation plan comments/todo stubs
- no engineer can reasonably misunderstand the intended single-sender end state

---

# Phase 1 - Backend notification semantics

## Purpose
Make notification intent explicit so the client stops guessing from generic chat events.

## Deliverables
- backend emits `notification.candidate`
- backend includes `delivery_phase`
- backend preserves stable ids and cursor semantics

## Tasks

### 1.1 Define backend event schema
Create a backend-side schema/DTO for `notification.candidate` with at least:
- `kind`
- `event_id`
- `seq`
- `delivery_phase`
- `session_id`
- `message_id`
- `message_kind`
- `dedupe_key`
- `created_at`
- optional `title`
- optional `body_preview`

### 1.2 Choose backend emission points
Audit where assistant/user messages become final enough to qualify as notification candidates.

For phase 1, define which events should become `notification.candidate`:
- assistant reply completion
- inbound human message if applicable
- optionally future mention/system classes

This mapping must be explicit and code-local, not scattered across ad hoc call sites.

### 1.3 Add `delivery_phase`
The backend stream layer must mark whether a delivered event is:
- `replay`
- `live`

This must be added by stream delivery infrastructure, not guessed by business logic.

### 1.4 Preserve resume semantics
Ensure the existing `since` / sequence replay behavior remains intact.

Requirement:
- replay items carry `delivery_phase=replay`
- live items carry `delivery_phase=live`

### 1.5 Validate candidate completeness
If an event cannot supply stable `session_id` and `message_id`, it must not become a notification candidate.

Do not emit partial candidate objects and hope the client compensates.

### 1.6 Add backend audit logs for candidate emission
Log candidate-emission facts such as:
- candidate created
- source event type
- session/message ids
- seq
- phase

This is separate from device-side final decision logs.

## Exit criteria
- client can receive explicit `notification.candidate` objects through the existing stream
- replay/live is explicit in the delivered payload
- no client inference is needed to decide whether a payload is a notification candidate

---

# Phase 2 - Android native notification engine

## Purpose
Create the single final authority for Android system notifications.

## Deliverables
- native notification decision engine
- stable dedupe store
- structured audit logs
- native stream consumer for notification candidates

## Tasks

### 2.1 Introduce a dedicated native module boundary
Create a clean package/module boundary on Android side, for example:
- `notification/NotificationDecisionEngine`
- `notification/NotificationRuntimeState`
- `notification/NotificationDedupeStore`
- `notification/NotificationAuditLogger`
- `notification/NotificationCandidateConsumer`

The exact names can differ, but the separation should be real.

### 2.2 Implement `NotificationRuntimeState`
The native layer should own one coherent runtime state structure.

Include at least:
- app foreground flag
- active session id
- notifications enabled
- stream connected
- last seen seq
- app process state
- last state transition timestamps if needed

### 2.3 Implement `NotificationDecisionEngine`
Decision engine must evaluate candidates in explicit order:
1. validate
2. replay suppression
3. settings suppression
4. duplicate suppression
5. foreground active-session suppression
6. stale suppression if configured
7. show

The engine must return a typed result, not just a bool.

### 2.4 Implement persistent dedupe store
Requirements:
- dedupe by `dedupe_key`
- survive foreground-service restarts
- bounded retention
- efficient membership lookup

Suggested implementation choices:
- SharedPreferences-backed JSON/LRU metadata for phase 1, if simple and bounded
- or Room/DataStore if the project already prefers that stack

Do not over-engineer storage, but do make it persistent.

### 2.5 Implement notification id strategy
Define a stable notification id strategy derived from stable business identity.

Guideline:
- based on `session_id` + `message_id`
- no teaser/body/localized text involvement

### 2.6 Implement native candidate consumer
The native side should consume only `notification.candidate` items from the event stream.

It must ignore generic chat progress events.

### 2.7 Implement replay gating
On receiving a candidate with `delivery_phase=replay`:
- update cursor/state if needed
- write audit record
- do not render system notification

### 2.8 Implement rendering adapter
Separate final decision from Android notification rendering.

Suggested split:
- decision engine: pure logic
- renderer: Android NotificationManager integration

This keeps tests clean.

### 2.9 Implement native audit logger
Every processed candidate must emit a structured decision log with:
- event id
- seq
- phase
- session id
- message id
- dedupe key
- decision
- reason
- notification id if any
- render success/failure

### 2.10 Add health logs around stream lifecycle
Track:
- stream connected
- stream disconnected
- reconnect start
- replay resumed from seq
- live mode entered

These logs matter for diagnosing delivery gaps.

## Exit criteria
- Android can receive `notification.candidate`
- replay items never show system notifications
- background live candidate shows exactly one notification
- duplicate candidate does not show again
- every candidate leaves a native audit trail

---

# Phase 3 - Flutter-to-native state bridge cleanup

## Purpose
Stop lifecycle and active-session state from being loosely duplicated and racy.

## Deliverables
- one coherent state bridge from Flutter to native notification engine
- deterministic ordering of active-session and lifecycle updates

## Tasks

### 3.1 Inventory all current state write paths
Audit current sources of notification-related state mutation in Flutter and bridge code, including:
- app lifecycle observers
- chat page active-session binding
- background connection service hooks
- notification service hooks
- back-navigation/background transition helpers

Classify each path as:
- keep
- merge
- delete
- move behind reducer

### 3.2 Define one bridge contract
Create one explicit bridge API from Flutter to native, for example:
- `updateNotificationRuntimeState(...)`
- or separate but coordinated methods with versioned payloads

The bridge payload should carry only stable state facts, not notification decisions.

### 3.3 Introduce reducer-style state assembly in Flutter
Flutter may still observe many lifecycle/page events, but it should assemble them into one coherent snapshot before crossing the native bridge.

This reduces out-of-order flag spam.

### 3.4 Define active-session semantics exactly
The app must have a precise definition of active session:
- session currently visible to user on focused chat screen
- not merely last opened
- not merely cached in state store

### 3.5 Define foreground semantics exactly
The app must distinguish:
- foreground interactive chat surface
- foreground non-chat screen
- background

Do not collapse all foreground states into one if policy differs.

### 3.6 Make bridge updates idempotent
Native side should tolerate repeated identical state updates.

### 3.7 Guard against stale updates
If needed, attach a monotonic sequence or timestamp to bridge state updates so the native side can ignore obviously older state writes.

### 3.8 Keep notification tap routing separate
Notification-tap handling should not mutate runtime state in surprising ways beyond the intentional navigation effect.

## Exit criteria
- Flutter has one coherent runtime-state bridge to native
- duplicated ad hoc state writes are removed or deprecated
- active-session suppression behavior is deterministic under rapid screen changes

---

# Phase 4 - Migration cleanup and sender unification

## Purpose
Remove the old split-brain behavior safely.

## Deliverables
- Android native is the only final Android system-notification sender
- Flutter no longer competes as a final sender
- old heuristics are removed

## Tasks

### 4.1 Identify all Flutter final-send paths
Find all places where Flutter directly triggers Android-visible notifications.

Classify:
- still needed for non-chat/non-Android-specific cases
- deprecated under the new Android notification engine

### 4.2 Disable competing final send path behind flag
During migration, allow temporary coexistence only behind explicit flags.

Preferred rollout:
- enable native engine first
- keep Flutter final send disabled for Android after verification

### 4.3 Remove teaser-based dedupe/id behavior everywhere
Any remaining code that hashes decorative preview text into notification identity must be deleted.

### 4.4 Remove generic chat-event guessing from notification logic
Once backend candidate semantics exist, stop turning generic progress/final events into notification decisions on the device.

### 4.5 Simplify foreground-service logic
The foreground service should become narrower:
- consume notification candidates
- maintain cursor
- maintain audit logs
- render notifications

It should stop owning unrelated inference logic that belongs elsewhere.

### 4.6 Add defensive startup diagnostics
At app/service startup, log:
- which sender path is active
- whether candidate semantics are enabled
- whether audit logging is enabled

This prevents “which codepath actually ran?” confusion.

## Exit criteria
- exactly one Android final sender remains active in intended production mode
- old dedupe and heuristic notification paths are gone or hard-disabled
- service startup logs clearly identify the active architecture path

---

# Phase 5 - Validation and testing

## Purpose
Prove the new architecture is correct under normal and edge conditions.

## Deliverables
- unit coverage for core logic
- integration coverage for replay/live transitions
- manual validation checklist
- log-based acceptance verification

## Tasks

### 5.1 Unit tests - backend semantics
Test:
- candidate emitted for qualifying message types
- non-qualifying events do not become candidates
- replay and live phases are labeled correctly
- invalid candidate data is rejected upstream

### 5.2 Unit tests - decision engine
Test:
- invalid candidate -> drop
- replay -> suppress replay
- duplicate -> suppress duplicate
- active foreground same session -> suppress
- background live -> show
- notifications disabled -> suppress
- foreground different session -> show (per approved decision)

### 5.3 Unit tests - dedupe store
Test:
- same dedupe key with different preview text
- persistence across restart
- bounded retention eviction
- duplicate after reconnect

### 5.4 Unit tests - runtime-state handling
Test:
- repeated identical updates
- rapid session switch ordering
- stale update rejection if sequence/timestamp guard is used
- foreground/non-chat/background transitions

### 5.5 Integration tests - replay burst
Scenario:
- connect live
- disconnect
- server accumulates candidate events
- reconnect with `since`
- replay delivered
- live resumes

Assert:
- replay advanced cursor
- replay generated audit logs
- replay showed zero visible notifications
- next live candidate showed exactly one notification if eligible

### 5.6 Integration tests - in-flight background transition
Scenario:
- user sends message in foreground
- app backgrounds before response finalizes
- assistant reply arrives

Assert:
- if delivered live while backgrounded -> one notification
- if only seen later via replay -> no retroactive replay notification

### 5.7 Integration tests - service restart
Scenario:
- deliver a notification
- persist dedupe state and cursor
- restart service
- replay same candidate

Assert:
- no duplicate visible notification

### 5.8 Integration tests - rapid session switching
Scenario:
- switch between session A and B quickly
- candidates arrive for both

Assert:
- active session suppression is deterministic
- non-active-session foreground behavior follows approved policy

### 5.9 Manual validation checklist
At minimum test manually:
- foreground same-session reply
- foreground other-session reply
- background reply
- offline/reconnect replay burst
- service restart
- notification tap navigation
- app opened on non-chat screen

### 5.10 Audit-log verification
For each manual scenario, verify that logs alone clearly explain:
- candidate arrival
- replay/live phase
- decision result
- render outcome

## Exit criteria
- automated tests cover the core policy matrix
- manual tests match expected product behavior
- audit logs are sufficient to diagnose any failure seen during validation

---

# Recommended sequencing

Implement in this order:

1. Phase 0 guardrails
2. Phase 1 backend semantics
3. Phase 2 native decision engine skeleton + audit logs
4. Phase 2 replay suppression + stable dedupe
5. Phase 3 Flutter/native state bridge cleanup
6. Phase 4 sender unification and old-path removal
7. Phase 5 full validation

Do **not** start by deleting existing Flutter notification code first.
That would reduce observability during migration and increase rollout risk.

---

# File-level impact map

This is intentionally approximate and should be refined during implementation.

## Backend likely touch points
- event stream route/service
- event bus/store delivery layer
- message finalization or assistant reply emission path
- any place currently shaping SSE payloads

## Android likely touch points
- foreground service stream consumer
- notification rendering code
- native bridge handlers
- persistence for dedupe/runtime state

## Flutter likely touch points
- notification service
- background connection service
- lifecycle wiring in app shell
- active-session binding in chat/session store or chat screen layer
- notification open/tap routing

## Likely deletions or deprecations
- teaser-based notification identity
- generic chat-progress-derived notification heuristics
- duplicate final-send codepath in Flutter for Android notifications

---

# Acceptance checkpoints

## Checkpoint A - backend semantic readiness
Complete when:
- candidate events exist
- delivery phase exists
- stream replay/live distinction is explicit

## Checkpoint B - native engine baseline
Complete when:
- native engine consumes candidates
- replay is suppressed
- background live notification works
- audit logs are present

## Checkpoint C - state coherence
Complete when:
- Flutter state bridge is unified
- active-session suppression is deterministic
- rapid session switching no longer produces ambiguous behavior

## Checkpoint D - migration completion
Complete when:
- Flutter is no longer a competing Android final sender
- only the new path remains in production mode

## Checkpoint E - validation closure
Complete when:
- all required tests pass
- manual scenarios pass
- logs explain every candidate outcome cleanly

---

# Things explicitly out of scope for the first implementation pass

Do not expand phase 1 into these unless a blocking reason appears:
- iOS notification architecture
- user-configurable notification rules UI
- session-batched summary notifications
- advanced notification ranking/personalization
- full dedicated notification stream endpoint

These can come after the architecture is sound.

---

# Definition of implementation readiness

Coding should begin only when:
- this implementation plan is accepted
- the architecture spec is accepted
- the active sender policy is understood by everyone touching the code
- at least one engineer can point to the exact backend emission point for `notification.candidate`
- at least one engineer can point to the exact native module boundary for the decision engine

## Summary

This implementation plan deliberately avoids patching symptoms.

It sequences the work so that:
- notification intent becomes explicit first
- native authority becomes real second
- state coherence is cleaned up third
- migration cleanup happens only after the new path is observable and trustworthy

That is the safest path to a mature, robust, and professional notification system.