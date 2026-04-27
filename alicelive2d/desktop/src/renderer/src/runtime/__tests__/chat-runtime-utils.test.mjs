import test from "node:test";
import assert from "node:assert/strict";

import {
  getConnectionStateAfterChatError,
  reconcileSessionMessages,
} from "../chat-runtime-utils.ts";

test("getConnectionStateAfterChatError keeps idle for AbortError", () => {
  assert.equal(
    getConnectionStateAfterChatError({ name: "AbortError" }),
    "idle",
  );
});

test("getConnectionStateAfterChatError marks non-abort failures as error", () => {
  assert.equal(
    getConnectionStateAfterChatError(new Error("network failed")),
    "error",
  );
});

test("reconcileSessionMessages preserves optimistic user ids when the server returns the same message", () => {
  const existingMessages = [
    {
      id: "user_optimistic_1",
      sessionId: "sess_1",
      role: "user",
      text: "你好",
      attachments: [],
      source: "chat",
      createdAt: 1711111111,
    },
  ];

  const nextMessages = [
    {
      id: "msg_server_user_1",
      sessionId: "sess_1",
      role: "user",
      text: "你好",
      attachments: [],
      source: "chat",
      createdAt: 1711111112,
    },
    {
      id: "msg_server_assistant_1",
      sessionId: "sess_1",
      role: "assistant",
      text: "你好呀",
      attachments: [],
      source: "chat",
      createdAt: 1711111113,
    },
  ];

  assert.deepEqual(
    reconcileSessionMessages(existingMessages, nextMessages).map((message) => message.id),
    ["user_optimistic_1", "msg_server_assistant_1"],
  );
});

test("reconcileSessionMessages preserves duplicate optimistic messages in order", () => {
  const existingMessages = [
    {
      id: "user_optimistic_1",
      sessionId: "sess_1",
      role: "user",
      text: "继续",
      attachments: [],
      source: "chat",
      createdAt: 1711111111,
    },
    {
      id: "user_optimistic_2",
      sessionId: "sess_1",
      role: "user",
      text: "继续",
      attachments: [],
      source: "chat",
      createdAt: 1711111112,
    },
  ];

  const nextMessages = [
    {
      id: "msg_server_user_1",
      sessionId: "sess_1",
      role: "user",
      text: "继续",
      attachments: [],
      source: "chat",
      createdAt: 1711111120,
    },
    {
      id: "msg_server_user_2",
      sessionId: "sess_1",
      role: "user",
      text: "继续",
      attachments: [],
      source: "chat",
      createdAt: 1711111121,
    },
  ];

  assert.deepEqual(
    reconcileSessionMessages(existingMessages, nextMessages).map((message) => message.id),
    ["user_optimistic_1", "user_optimistic_2"],
  );
});

test("reconcileSessionMessages tolerates server-side attachment decoration for optimistic user messages", () => {
  const existingMessages = [
    {
      id: "user_optimistic_1",
      sessionId: "sess_1",
      role: "user",
      text: "看这个",
      attachments: [
        {
          mimeType: "image/png",
          data: "BASE64_PAYLOAD",
        },
      ],
      source: "chat",
      createdAt: 1711111111,
    },
  ];

  const nextMessages = [
    {
      id: "msg_server_user_1",
      sessionId: "sess_1",
      role: "user",
      text: "看这个",
      attachments: [
        {
          kind: "image",
          mimeType: "image/png",
          data: "BASE64_PAYLOAD",
        },
      ],
      source: "chat",
      createdAt: 1711111112,
    },
  ];

  assert.deepEqual(
    reconcileSessionMessages(existingMessages, nextMessages).map((message) => message.id),
    ["user_optimistic_1"],
  );
});
