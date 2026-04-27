import test from "node:test";
import assert from "node:assert/strict";

import {
  applyFailedMotionPreload,
  applySuccessfulMotionPreload,
} from "../live2d-motion-preload-utils.ts";

test("applySuccessfulMotionPreload waits for the remaining motions", () => {
  const result = applySuccessfulMotionPreload({
    loadedCount: 1,
    totalCount: 3,
  });

  assert.deepEqual(result, {
    loadedCount: 2,
    totalCount: 3,
    shouldFinalizeSetup: false,
  });
});

test("applyFailedMotionPreload finalizes setup when the last outstanding motion fails", () => {
  const result = applyFailedMotionPreload({
    loadedCount: 1,
    totalCount: 2,
  });

  assert.deepEqual(result, {
    loadedCount: 1,
    totalCount: 1,
    shouldFinalizeSetup: true,
  });
});

test("applyFailedMotionPreload also finalizes when every motion has failed", () => {
  const result = applyFailedMotionPreload({
    loadedCount: 0,
    totalCount: 1,
  });

  assert.deepEqual(result, {
    loadedCount: 0,
    totalCount: 0,
    shouldFinalizeSetup: true,
  });
});
