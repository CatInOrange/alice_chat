import test from "node:test";
import assert from "node:assert/strict";

import { applyLive2DFocus } from "../live2d-focus-utils.ts";

test("applyLive2DFocus prefers model.focus when available", () => {
  const calls = [];
  const handled = applyLive2DFocus({
    config: { enabled: true, headRatio: 0.25 },
    pointer: { x: 160, y: 120 },
    canvasRect: { left: 0, top: 0, width: 400, height: 300 },
    model: {
      y: 180,
      height: 200,
      focus: (x, y, instant) => calls.push({ x, y, instant }),
    },
    manager: {
      onDrag: () => calls.push("drag"),
    },
    view: {
      transformViewX: (value) => value,
      transformViewY: (value) => value,
    },
    devicePixelRatio: 1,
  });

  assert.equal(handled, true);
  assert.equal(calls.length, 1);
  assert.equal(typeof calls[0].x, "number");
  assert.equal(calls[0].instant, false);
});

test("applyLive2DFocus falls back to WebSDK drag tracking when model.focus is unavailable", () => {
  const dragCalls = [];
  const handled = applyLive2DFocus({
    config: { enabled: true, headRatio: 0.25 },
    pointer: { x: 160, y: 120 },
    canvasRect: { left: 10, top: 20, width: 400, height: 300 },
    model: {
      y: 180,
      height: 200,
    },
    manager: {
      onDrag: (x, y) => dragCalls.push({ x, y }),
    },
    view: {
      transformViewX: (value) => Number((value / 100).toFixed(2)),
      transformViewY: (value) => Number((value / 100).toFixed(2)),
    },
    devicePixelRatio: 2,
  });

  assert.equal(handled, true);
  assert.deepEqual(dragCalls, [{ x: 3, y: 2.4 }]);
});
