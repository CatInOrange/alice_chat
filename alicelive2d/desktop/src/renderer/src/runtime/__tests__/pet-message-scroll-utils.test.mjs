import test from "node:test";
import assert from "node:assert/strict";

import { shouldScrollPetMessagesToBottom } from "../pet-message-scroll-utils.ts";

test("shouldScrollPetMessagesToBottom when entering chat surface", () => {
  assert.equal(shouldScrollPetMessagesToBottom({
    previousSurface: "settings",
    nextSurface: "chat",
    previousMessageCount: 4,
    nextMessageCount: 4,
    previousExpanded: false,
    nextExpanded: false,
  }), true);
});

test("shouldScrollPetMessagesToBottom when new messages arrive in chat surface", () => {
  assert.equal(shouldScrollPetMessagesToBottom({
    previousSurface: "chat",
    nextSurface: "chat",
    previousMessageCount: 4,
    nextMessageCount: 5,
    previousLatestMessageId: "msg_4",
    nextLatestMessageId: "msg_5",
    previousExpanded: false,
    nextExpanded: false,
  }), true);
});

test("shouldScrollPetMessagesToBottom when visible window stays full but latest message changes", () => {
  assert.equal(shouldScrollPetMessagesToBottom({
    previousSurface: "chat",
    nextSurface: "chat",
    previousMessageCount: 8,
    nextMessageCount: 8,
    previousLatestMessageId: "msg_8",
    nextLatestMessageId: "msg_9",
    previousExpanded: false,
    nextExpanded: false,
  }), true);
});

test("shouldScrollPetMessagesToBottom when chat panel height changes", () => {
  assert.equal(shouldScrollPetMessagesToBottom({
    previousSurface: "chat",
    nextSurface: "chat",
    previousMessageCount: 4,
    nextMessageCount: 4,
    previousLatestMessageId: "msg_4",
    nextLatestMessageId: "msg_4",
    previousExpanded: false,
    nextExpanded: true,
  }), true);
});

test("shouldScrollPetMessagesToBottom stays false for non-chat surfaces without changes", () => {
  assert.equal(shouldScrollPetMessagesToBottom({
    previousSurface: "plus",
    nextSurface: "plus",
    previousMessageCount: 4,
    nextMessageCount: 4,
    previousLatestMessageId: "msg_4",
    nextLatestMessageId: "msg_4",
    previousExpanded: false,
    nextExpanded: false,
  }), false);
});
