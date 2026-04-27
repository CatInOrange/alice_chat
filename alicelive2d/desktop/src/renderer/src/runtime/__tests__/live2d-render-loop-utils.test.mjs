import test from "node:test";
import assert from "node:assert/strict";

import { shouldRenderLive2DFrame } from "../live2d-render-loop-utils.ts";

test("shouldRenderLive2DFrame returns true for the active initialized delegate", () => {
  const instance = {};
  const view = {};
  const glContext = {};

  assert.equal(
    shouldRenderLive2DFrame({
      activeInstance: instance,
      loopInstance: instance,
      view,
      glContext,
    }),
    true,
  );
});

test("shouldRenderLive2DFrame stops stale loops after the active delegate instance changes", () => {
  assert.equal(
    shouldRenderLive2DFrame({
      activeInstance: {},
      loopInstance: {},
      view: {},
      glContext: {},
    }),
    false,
  );
});

test("shouldRenderLive2DFrame stops rendering when the view has already been released", () => {
  const instance = {};

  assert.equal(
    shouldRenderLive2DFrame({
      activeInstance: instance,
      loopInstance: instance,
      view: null,
      glContext: {},
    }),
    false,
  );
});

test("shouldRenderLive2DFrame stops rendering when the WebGL context is unavailable", () => {
  const instance = {};

  assert.equal(
    shouldRenderLive2DFrame({
      activeInstance: instance,
      loopInstance: instance,
      view: {},
      glContext: null,
    }),
    false,
  );
});
