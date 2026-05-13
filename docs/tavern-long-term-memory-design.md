# Tavern Long-Term Memory Design

## Goal

Add a durable long-term memory layer on top of the new chunked oldest-first summary system.

Current stack after the summary refactor:
1. recent raw messages
2. recent chunk summaries

Target stack:
1. long-term memory facts / state
2. recent chunk summaries
3. recent raw messages

This separates stable facts from narrative compression.

---

## Why we need this

Chunk summaries are good at compressing old dialogue, but they are still narrative snapshots.
They are not ideal for storing durable state such as:

- character relationship changes
- promises and obligations
- identity / role assumptions
- user preferences that persist across scenes
- unresolved long-running threads
- world-state changes that remain canon
- taboo / consent / boundary facts

If these only live inside chunk summaries:
- they may be dropped when old chunks are trimmed
- they are harder to query deterministically
- they are more sensitive to summary quality drift

So long-term memory should be its own layer.

---

## Memory model

Store long-term memory in chat metadata, separate from `summaries`.

Suggested field:

```json
metadata.longTermMemory = {
  "version": 1,
  "updatedAt": 0,
  "items": []
}
```

Suggested memory item shape:

```json
{
  "id": "ltm_xxx",
  "category": "relationship | identity | preference | promise | world_state | unresolved_thread | boundary | note",
  "content": "text",
  "priority": 1,
  "confidence": 0.9,
  "createdAt": 0,
  "updatedAt": 0,
  "sourceSummaryIds": ["sum_xxx"],
  "sourceMessageIds": ["msg_xxx"],
  "active": true
}
```

---

## Layer responsibilities

### Long-term memory
Only durable, reusable facts.
Should be compact, stable, and low-churn.

### Chunk summaries
Narrative compression of older dialogue segments.
Keeps temporal progression and scene continuity.

### Recent raw
Preserves exact local tone, pacing, and immediate scene flow.

---

## Generation strategy

Long-term memory should not be regenerated every turn.

Recommended trigger:
- after one or more new chunk summaries are created
- optionally debounce: only refresh every N chunks or after significant state changes

Current Phase 2 implementation:
1. chunk summaries are generated first
2. one extraction call runs over:
   - existing long-term memory items
   - newly generated chunk summaries from this batch
3. model returns JSON memory candidates
4. merge step applies updates / deactivations / additions
5. metadata.longTermMemory is rewritten and latest prompt debug rebuilt

This is intentionally incremental and conservative.

---

## Prompt injection strategy

Inject order should be:
1. long-term memory
2. recent summary chunks
3. recent raw history
4. current user input

Long-term memory is injected as a compact dedicated block:

```text
[Long-term memory]
- Relationship: ...
- Promise: ...
- World state: ...
```

Token control:
- sort by priority
- prefer active items only
- cap total injected memory item count
- cap by token budget

Current defaults:
- max injected long-term memory items: 8
- max injected long-term memory tokens: 800

---

## Update semantics

Need overwrite semantics, not append-only.

Examples:
- relationship changed from hostile to trusting
- user preference changed
- unresolved thread became resolved

Current merge rules:
- `replaceIds` deactivates referenced old items
- same `id` updates the existing item
- fallback dedupe key is category + normalized content prefix
- incoming items can mark `active=false`
- merged list is re-sorted by active -> priority -> updatedAt

This is enough for Phase 2, but still heuristic.

---

## Extraction contract

Current extractor expects strict JSON:

```json
{
  "items": [
    {
      "id": "optional",
      "category": "promise",
      "content": "...",
      "priority": 3,
      "confidence": 0.9,
      "active": true,
      "replaceIds": ["lt_old"]
    }
  ]
}
```

Allowed categories:
- relationship
- identity
- preference
- promise
- world_state
- unresolved_thread
- boundary
- note

Anything outside this set is normalized to `note`.

---

## UI / settings

Current exposed settings:

```json
summarySettings.longTermMemoryEnabled = true
summarySettings.maxInjectedLongTermItems = 8
summarySettings.maxInjectedLongTermTokens = 800
```

Current UI capabilities:
- view long-term memory items
- see category / content / active / priority / confidence
- configure injection on/off and budgets
- manual add / edit / delete
- manual activate / deactivate
- quick pin via priority=5 shortcut

Not implemented yet:
- dedicated pinned field separate from priority
- source tracing UI

---

## Remaining work

### Next recommended step
- add sourceSummaryIds during extraction merge more aggressively
- expose memory count / source in debug panel more clearly
- let users manually edit / deactivate items

### Later
- smarter entity/topic based merge
- stronger contradiction handling
- selective category filtering per character/chat
- extraction debounce / batch strategy
- hybrid memory retrieval if item count grows large

---

## Current architecture summary

The system is now split into three distinct context layers:
- long-term memory = stable facts
- chunk summaries = compressed narrative history
- recent raw = exact local continuity

That separation is the core win of this design.
