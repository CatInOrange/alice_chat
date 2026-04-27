import test from "node:test";
import assert from "node:assert/strict";

import {
  canInitializeLive2DDelegate,
  resolveLive2DGlContext,
} from "../live2d-gl-context-utils.ts";

test("resolveLive2DGlContext prefers webgl2 when available", () => {
  const calls = [];
  const webgl2 = { kind: "webgl2" };

  const context = resolveLive2DGlContext({
    getContext(kind) {
      calls.push(kind);
      return kind === "webgl2" ? webgl2 : null;
    },
  });

  assert.equal(context, webgl2);
  assert.deepEqual(calls, ["webgl2"]);
});

test("resolveLive2DGlContext falls back to webgl when webgl2 is unavailable", () => {
  const calls = [];
  const webgl = { kind: "webgl" };

  const context = resolveLive2DGlContext({
    getContext(kind) {
      calls.push(kind);
      return kind === "webgl" ? webgl : null;
    },
  });

  assert.equal(context, webgl);
  assert.deepEqual(calls, ["webgl2", "webgl"]);
});

test("resolveLive2DGlContext returns null when no WebGL context can be created", () => {
  const context = resolveLive2DGlContext({
    getContext() {
      return null;
    },
  });

  assert.equal(context, null);
});

test("canInitializeLive2DDelegate requires both canvas and gl", () => {
  assert.equal(canInitializeLive2DDelegate({ canvas: {}, gl: {} }), true);
  assert.equal(canInitializeLive2DDelegate({ canvas: null, gl: {} }), false);
  assert.equal(canInitializeLive2DDelegate({ canvas: {}, gl: null }), false);
});
