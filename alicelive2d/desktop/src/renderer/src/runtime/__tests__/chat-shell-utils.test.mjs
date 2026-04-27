import test from "node:test";
import assert from "node:assert/strict";

import {
  getLunariaScrollbarStyles,
  shouldAutoScrollMessageList,
} from "../chat-shell-utils.ts";

test("shouldAutoScrollMessageList scrolls to the latest message when the active session changes", () => {
  assert.equal(
    shouldAutoScrollMessageList({
      previousSessionId: "session-1",
      nextSessionId: "session-2",
      previousMessageCount: 4,
      nextMessageCount: 4,
      previousStreamingText: "",
      nextStreamingText: "",
    }),
    true,
  );
});

test("shouldAutoScrollMessageList scrolls when a new message is appended", () => {
  assert.equal(
    shouldAutoScrollMessageList({
      previousSessionId: "session-1",
      nextSessionId: "session-1",
      previousMessageCount: 4,
      nextMessageCount: 5,
      previousStreamingText: "",
      nextStreamingText: "",
    }),
    true,
  );
});

test("shouldAutoScrollMessageList scrolls while the streaming preview grows", () => {
  assert.equal(
    shouldAutoScrollMessageList({
      previousSessionId: "session-1",
      nextSessionId: "session-1",
      previousMessageCount: 4,
      nextMessageCount: 4,
      previousStreamingText: "hel",
      nextStreamingText: "hello",
    }),
    true,
  );
});

test("shouldAutoScrollMessageList stays put when neither the session nor message content changed", () => {
  assert.equal(
    shouldAutoScrollMessageList({
      previousSessionId: "session-1",
      nextSessionId: "session-1",
      previousMessageCount: 4,
      nextMessageCount: 4,
      previousStreamingText: "hello",
      nextStreamingText: "hello",
    }),
    false,
  );
});

test("getLunariaScrollbarStyles returns a slimmer light-theme scrollbar", () => {
  assert.deepEqual(
    getLunariaScrollbarStyles(),
    {
      scrollbarWidth: "thin",
      scrollbarColor: "rgba(189, 161, 147, 0.52) transparent",
      "&::-webkit-scrollbar": {
        width: "6px",
      },
      "&::-webkit-scrollbar-track": {
        background: "transparent",
      },
      "&::-webkit-scrollbar-thumb": {
        background: "rgba(189, 161, 147, 0.52)",
        borderRadius: "999px",
      },
      "&::-webkit-scrollbar-thumb:hover": {
        background: "rgba(171, 142, 128, 0.72)",
      },
    },
  );
});

test("getLunariaScrollbarStyles can hide the scrollbar while keeping scroll behavior", () => {
  assert.deepEqual(
    getLunariaScrollbarStyles({ hidden: true }),
    {
      scrollbarWidth: "none",
      msOverflowStyle: "none",
      "&::-webkit-scrollbar": {
        display: "none",
      },
    },
  );
});
