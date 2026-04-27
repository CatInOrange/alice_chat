import test from "node:test";
import assert from "node:assert/strict";

import {
  getDraggedPetAnchor,
  shouldUpdatePetAnchor,
  resolvePetAnchorUpdate,
  resolvePetShellHoverState,
} from "../pet-shell-interaction-utils.ts";

test("resolvePetShellHoverState clears hover when the pet surface is hidden", () => {
  assert.equal(
    resolvePetShellHoverState({
      petSurface: "hidden",
      isHovering: true,
    }),
    false,
  );
});

test("resolvePetShellHoverState preserves hover for visible pet surfaces", () => {
  assert.equal(
    resolvePetShellHoverState({
      petSurface: "chat",
      isHovering: true,
    }),
    true,
  );
});

test("resolvePetAnchorUpdate keeps the manual anchor while dragging is locked", () => {
  assert.deepEqual(
    resolvePetAnchorUpdate({
      currentAnchor: { x: 280, y: 160 },
      nextAnchor: { x: 40, y: 24 },
      isLocked: true,
    }),
    { x: 280, y: 160 },
  );
});

test("resolvePetAnchorUpdate accepts synced anchors when not manually locked", () => {
  assert.deepEqual(
    resolvePetAnchorUpdate({
      currentAnchor: { x: 280, y: 160 },
      nextAnchor: { x: 40, y: 24 },
      isLocked: false,
    }),
    { x: 40, y: 24 },
  );
});

test("shouldUpdatePetAnchor ignores equal coordinates even when the object identity changes", () => {
  assert.equal(
    shouldUpdatePetAnchor({
      currentAnchor: { x: 280, y: 160 },
      nextAnchor: { x: 280, y: 160 },
    }),
    false,
  );
});

test("shouldUpdatePetAnchor returns true when either coordinate changes", () => {
  assert.equal(
    shouldUpdatePetAnchor({
      currentAnchor: { x: 280, y: 160 },
      nextAnchor: { x: 281, y: 160 },
    }),
    true,
  );
});

test("getDraggedPetAnchor applies pointer deltas to the starting anchor", () => {
  assert.deepEqual(
    getDraggedPetAnchor({
      startAnchor: { x: 120, y: 220 },
      dragStart: { x: 400, y: 500 },
      pointer: { x: 460, y: 455 },
    }),
    { x: 180, y: 175 },
  );
});
