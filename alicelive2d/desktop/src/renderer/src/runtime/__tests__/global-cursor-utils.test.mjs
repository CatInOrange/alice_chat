import test from "node:test";
import assert from "node:assert/strict";

import {
  shouldUseGlobalCursorTracking,
  toRendererPointerFromScreenPoint,
  toRendererPointerFromWindowContentPoint,
} from "../global-cursor-utils.ts";

test("shouldUseGlobalCursorTracking enables polling for window and pet modes when mouse follow is on", () => {
  assert.equal(
    shouldUseGlobalCursorTracking({
      mode: "window",
      focusCenter: { enabled: true },
    }),
    true,
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

test("toRendererPointerFromWindowContentPoint converts screen coordinates into window-content-local coordinates", () => {
  assert.deepEqual(
    toRendererPointerFromWindowContentPoint({
      screenPoint: { x: 980, y: 620 },
      contentBounds: { x: 320, y: 140, width: 900, height: 670 },
    }),
    { x: 660, y: 480 },
  );
});

test("toRendererPointerFromWindowContentPoint returns null when bounds are missing", () => {
  assert.equal(
    toRendererPointerFromWindowContentPoint({
      screenPoint: { x: 980, y: 620 },
      contentBounds: null,
    }),
    null,
  );
});
