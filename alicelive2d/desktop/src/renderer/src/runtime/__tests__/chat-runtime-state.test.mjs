import test from "node:test";
import assert from "node:assert/strict";

import { resolveCommittedChatState } from "../chat-runtime-utils.ts";

test("resolveCommittedChatState replaces the session messages and clears same-session streaming together", () => {
  const nextState = resolveCommittedChatState({
    messagesBySession: {
      session_1: [
        {
          id: "user_optimistic_1",
          sessionId: "session_1",
          role: "user",
          text: "你好",
          attachments: [],
          source: "chat",
          createdAt: 1711111111,
        },
      ],
    },
    streamingMessage: {
      id: "stream_1",
      sessionId: "session_1",
      text: "你好呀",
      rawText: "你好呀",
      createdAt: 1711111112,
    },
    sessionId: "session_1",
    messages: [
      {
        id: "msg_server_user_1",
        sessionId: "session_1",
        role: "user",
        text: "你好",
        attachments: [],
        source: "chat",
        createdAt: 1711111113,
      },
      {
        id: "msg_server_assistant_1",
        sessionId: "session_1",
        role: "assistant",
        text: "你好呀",
        attachments: [],
        source: "chat",
        createdAt: 1711111114,
      },
    ],
  });

  assert.deepEqual(
    nextState.messagesBySession.session_1.map((message) => message.id),
    ["user_optimistic_1", "msg_server_assistant_1"],
  );
  assert.equal(nextState.streamingMessage, null);
});
