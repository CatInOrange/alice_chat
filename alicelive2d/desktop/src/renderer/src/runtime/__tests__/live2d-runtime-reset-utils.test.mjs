import test from "node:test";
import assert from "node:assert/strict";

import { resetLive2DRuntime } from "../live2d-runtime-reset-utils.ts";

test("resetLive2DRuntime releases runtime singletons in dependency order", () => {
  const calls = [];

  resetLive2DRuntime({
    releaseDelegate: () => calls.push("delegate"),
    releaseGlManager: () => calls.push("gl"),
    releaseLive2DManager: () => calls.push("manager"),
  });

  assert.deepEqual(calls, ["delegate", "gl", "manager"]);
});

test("resetLive2DRuntime tolerates missing release hooks", () => {
  assert.doesNotThrow(() => {
    resetLive2DRuntime({
      releaseDelegate: () => {},
    });
  });
});
