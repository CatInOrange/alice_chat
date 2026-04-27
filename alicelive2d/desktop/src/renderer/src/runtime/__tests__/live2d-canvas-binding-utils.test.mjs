import test from "node:test";
import assert from "node:assert/strict";

import { resolveActiveLive2DCanvas } from "../live2d-canvas-binding-utils.ts";

test("resolveActiveLive2DCanvas keeps the current canvas when it is still connected", () => {
  const currentCanvas = { id: "old", isConnected: true };
  const nextCanvas = { id: "new", isConnected: true };

  assert.equal(
    resolveActiveLive2DCanvas({
      currentCanvas,
      nextCanvas,
    }),
    currentCanvas,
  );
});

test("resolveActiveLive2DCanvas switches to the new canvas when the old one is disconnected", () => {
  const currentCanvas = { id: "old", isConnected: false };
  const nextCanvas = { id: "new", isConnected: true };

  assert.equal(
    resolveActiveLive2DCanvas({
      currentCanvas,
      nextCanvas,
    }),
    nextCanvas,
  );
});

test("resolveActiveLive2DCanvas adopts the first discovered canvas", () => {
  const nextCanvas = { id: "canvas", isConnected: true };

  assert.equal(
    resolveActiveLive2DCanvas({
      currentCanvas: null,
      nextCanvas,
    }),
    nextCanvas,
  );
});
