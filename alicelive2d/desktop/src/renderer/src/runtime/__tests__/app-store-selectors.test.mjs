import test from "node:test";
import assert from "node:assert/strict";

import { selectCurrentSessionMessages } from "../app-store-selectors.ts";

test("selectCurrentSessionMessages returns a stable empty array before a session is selected", () => {
  const state = {
    currentSessionId: null,
    messagesBySession: {},
  };

  const first = selectCurrentSessionMessages(state);
  const second = selectCurrentSessionMessages(state);

  assert.equal(first, second);
  assert.deepEqual(first, []);
});

test("selectCurrentSessionMessages returns the current session messages when available", () => {
  const messages = [{ id: "msg_1", text: "hello" }];
  const state = {
    currentSessionId: "session_1",
    messagesBySession: {
      session_1: messages,
    },
  };

  assert.equal(selectCurrentSessionMessages(state), messages);
});
