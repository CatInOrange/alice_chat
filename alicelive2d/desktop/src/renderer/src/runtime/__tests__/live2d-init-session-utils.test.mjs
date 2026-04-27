import test from "node:test";
import assert from "node:assert/strict";

import {
  beginLive2DInitializationSession,
  getActiveLive2DInitializationSession,
  isLive2DInitializationSessionCurrent,
  shouldContinueLive2DAssetLoad,
} from "../live2d-init-session-utils.ts";

test("beginLive2DInitializationSession invalidates the previous session", () => {
  const store = { activeSessionId: 0 };

  const firstSessionId = beginLive2DInitializationSession(store);
  const secondSessionId = beginLive2DInitializationSession(store);

  assert.equal(firstSessionId, 1);
  assert.equal(secondSessionId, 2);
  assert.equal(getActiveLive2DInitializationSession(store), 2);
  assert.equal(isLive2DInitializationSessionCurrent(firstSessionId, store), false);
  assert.equal(isLive2DInitializationSessionCurrent(secondSessionId, store), true);
});

test("shouldContinueLive2DAssetLoad rejects stale or disposed model loads", () => {
  const store = { activeSessionId: 3 };

  assert.equal(
    shouldContinueLive2DAssetLoad({
      sessionId: 2,
      store,
      isStarted: true,
      isInitialized: true,
    }),
    false,
  );

  assert.equal(
    shouldContinueLive2DAssetLoad({
      sessionId: 3,
      store,
      isStarted: true,
      isInitialized: true,
      isReleased: true,
    }),
    false,
  );

  assert.equal(
    shouldContinueLive2DAssetLoad({
      sessionId: 3,
      store,
      isStarted: true,
      isInitialized: true,
      isReleased: false,
    }),
    true,
  );
});
