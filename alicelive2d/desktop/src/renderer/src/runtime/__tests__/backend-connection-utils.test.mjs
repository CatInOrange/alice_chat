import test from "node:test";
import assert from "node:assert/strict";

import {
  beginBackendConnectionSession,
  isBackendConnectionSessionCurrent,
  shouldApplyBackendConnectionUpdate,
  shouldPreferConfiguredBackendUrl,
} from "../backend-connection-utils.ts";

test("beginBackendConnectionSession invalidates the previous backend session", () => {
  const store = { activeSessionId: 0 };

  const firstSessionId = beginBackendConnectionSession(store);
  const secondSessionId = beginBackendConnectionSession(store);

  assert.equal(firstSessionId, 1);
  assert.equal(secondSessionId, 2);
  assert.equal(isBackendConnectionSessionCurrent(firstSessionId, store), false);
  assert.equal(isBackendConnectionSessionCurrent(secondSessionId, store), true);
});

test("shouldApplyBackendConnectionUpdate rejects stale or disposed sessions", () => {
  const store = { activeSessionId: 3 };

  assert.equal(
    shouldApplyBackendConnectionUpdate({
      sessionId: 2,
      store,
    }),
    false,
  );

  assert.equal(
    shouldApplyBackendConnectionUpdate({
      sessionId: 3,
      store,
      isDisposed: true,
    }),
    false,
  );

  assert.equal(
    shouldApplyBackendConnectionUpdate({
      sessionId: 3,
      store,
      isDisposed: false,
    }),
    true,
  );
});

test("shouldPreferConfiguredBackendUrl uses the desktop config when the renderer is still on the localhost default", () => {
  assert.equal(
    shouldPreferConfiguredBackendUrl({
      currentUrl: "http://127.0.0.1:18080",
      configuredUrl: "https://lunaria.example.com/api",
    }),
    true,
  );
});

test("shouldPreferConfiguredBackendUrl keeps an existing user override", () => {
  assert.equal(
    shouldPreferConfiguredBackendUrl({
      currentUrl: "https://user-selected.example.com",
      configuredUrl: "https://lunaria.example.com/api",
    }),
    false,
  );
});
