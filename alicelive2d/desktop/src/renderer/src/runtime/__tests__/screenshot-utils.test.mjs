import test from "node:test";
import assert from "node:assert/strict";

import {
  clampSelectionRect,
  createFullScreenSelection,
  hasMeaningfulSelection,
  selectionCoversBounds,
  toPositiveRect,
} from "../screenshot-utils.ts";

test("toPositiveRect normalizes drag direction", () => {
  assert.deepEqual(
    toPositiveRect({ x: 120, y: 80 }, { x: 20, y: 10 }),
    { x: 20, y: 10, width: 100, height: 70 },
  );
});

test("clampSelectionRect keeps the selection inside image bounds", () => {
  assert.deepEqual(
    clampSelectionRect(
      { x: -10, y: 20, width: 180, height: 120 },
      { width: 100, height: 80 },
    ),
    { x: 0, y: 20, width: 100, height: 60 },
  );
});

test("hasMeaningfulSelection rejects tiny drags", () => {
  assert.equal(hasMeaningfulSelection({ x: 0, y: 0, width: 8, height: 30 }), false);
  assert.equal(hasMeaningfulSelection({ x: 0, y: 0, width: 28, height: 24 }), true);
});

test("createFullScreenSelection covers the full displayed screenshot", () => {
  assert.deepEqual(
    createFullScreenSelection({ width: 1920, height: 1080 }),
    { x: 0, y: 0, width: 1920, height: 1080 },
  );
});

test("selectionCoversBounds detects a full-screen selection", () => {
  const bounds = { width: 1920, height: 1080 };
  assert.equal(selectionCoversBounds(createFullScreenSelection(bounds), bounds), true);
  assert.equal(selectionCoversBounds({ x: 12, y: 0, width: 1908, height: 1080 }, bounds), false);
});
