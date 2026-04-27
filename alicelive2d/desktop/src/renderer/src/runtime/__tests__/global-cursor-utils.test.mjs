import test from "node:test";
import assert from "node:assert/strict";

import {
  shouldUseGlobalCursorTracking,
  toRendererPointerFromScreenPoint,
} from "../global-cursor-utils.ts";

test("shouldUseGlobalCursorTracking only enables polling for pet mode when mouse follow is on", () => {
  assert.equal(
    shouldUseGlobalCursorTracking({
      mode: "window",
      focusCenter: { enabled: true },
    }),
    false,
  );

  assert.equal(
    shouldUseGlobalCursorTracking({
      mode: "pet",
      focusCenter: { enabled: false },
    }),
    false,
  );

  assert.equal(
    shouldUseGlobalCursorTracking({
      mode: "pet",
      focusCenter: { enabled: true },
    }),
    true,
  );
});

test("toRendererPointerFromScreenPoint converts screen coordinates into overlay-local coordinates", () => {
  assert.deepEqual(
    toRendererPointerFromScreenPoint({
      screenPoint: { x: 1680, y: 940 },
      virtualBounds: { x: 1440, y: 0, width: 2560, height: 1440 },
    }),
    { x: 240, y: 940 },
  );
});

test("toRendererPointerFromScreenPoint returns null when point data is missing", () => {
  assert.equal(
    toRendererPointerFromScreenPoint({
      screenPoint: null,
      virtualBounds: { x: 0, y: 0, width: 1920, height: 1080 },
    }),
    null,
  );
});
