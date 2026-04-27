import test from "node:test";
import assert from "node:assert/strict";

import {
  cancelScheduledLive2DInitialization,
  scheduleLive2DInitialization,
} from "../live2d-init-scheduler-utils.ts";

test("scheduleLive2DInitialization clears the previous pending timer before scheduling a new one", () => {
  const cleared = [];
  const scheduled = [];

  const firstTimer = scheduleLive2DInitialization({
    currentTimer: null,
    delayMs: 500,
    clearTimeoutImpl: (timer) => cleared.push(timer),
    setTimeoutImpl: (callback, delay) => {
      scheduled.push({ callback, delay });
      return "timer_1";
    },
    onInitialize: () => {},
  });

  const secondTimer = scheduleLive2DInitialization({
    currentTimer: firstTimer,
    delayMs: 500,
    clearTimeoutImpl: (timer) => cleared.push(timer),
    setTimeoutImpl: (callback, delay) => {
      scheduled.push({ callback, delay });
      return "timer_2";
    },
    onInitialize: () => {},
  });

  assert.equal(firstTimer, "timer_1");
  assert.equal(secondTimer, "timer_2");
  assert.deepEqual(cleared, ["timer_1"]);
  assert.equal(scheduled.length, 2);
  assert.deepEqual(scheduled.map((entry) => entry.delay), [500, 500]);
});

test("cancelScheduledLive2DInitialization clears the active timer and returns null", () => {
  const cleared = [];

  const nextTimer = cancelScheduledLive2DInitialization({
    currentTimer: "timer_2",
    clearTimeoutImpl: (timer) => cleared.push(timer),
  });

  assert.equal(nextTimer, null);
  assert.deepEqual(cleared, ["timer_2"]);
});
