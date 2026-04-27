import test from "node:test";
import assert from "node:assert/strict";

import { getSessionStoreUpdateForBackendUrl } from "../session-store-utils.ts";

test("getSessionStoreUpdateForBackendUrl preserves the last event sequence for the same backend url", () => {
  assert.deepEqual(
    getSessionStoreUpdateForBackendUrl({
      currentBackendUrl: "http://127.0.0.1:18080",
      currentLastEventSeq: 42,
      nextBackendUrl: "http://127.0.0.1:18080",
    }),
    {
      backendUrl: "http://127.0.0.1:18080",
      lastEventSeq: 42,
    },
  );
});

test("getSessionStoreUpdateForBackendUrl resets the last event sequence after switching backend urls", () => {
  assert.deepEqual(
    getSessionStoreUpdateForBackendUrl({
      currentBackendUrl: "http://127.0.0.1:18080",
      currentLastEventSeq: 42,
      nextBackendUrl: "http://127.0.0.1:19090",
    }),
    {
      backendUrl: "http://127.0.0.1:19090",
      lastEventSeq: 0,
    },
  );
});
