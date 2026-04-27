import test from "node:test";
import assert from "node:assert/strict";

import {
  getComposerAction,
  mapLunariaMessageToDisplayMessage,
  resolveAutomationNoteKind,
} from "../chat-surface-utils.ts";

test("getComposerAction returns noop when nothing to send and nothing streaming", () => {
  assert.equal(getComposerAction({
    hasContent: false,
    isStreaming: false,
  }), "noop");
});

test("getComposerAction returns interrupt while streaming", () => {
  assert.equal(getComposerAction({
    hasContent: false,
    isStreaming: true,
  }), "interrupt");
});

test("getComposerAction returns send when draft or attachments exist", () => {
  assert.equal(getComposerAction({
    hasContent: true,
    isStreaming: false,
  }), "send");
});

test("mapLunariaMessageToDisplayMessage converts runtime messages for the legacy pet list", () => {
  const message = {
    id: "msg_1",
    role: "assistant",
    text: "你好呀",
    meta: "Sample Model",
    createdAt: 1711111111,
    attachments: [{ kind: "image", url: "/uploads/demo.png" }],
  };

  assert.deepEqual(mapLunariaMessageToDisplayMessage(message), {
    id: "msg_1",
    content: "你好呀",
    role: "ai",
    timestamp: new Date(1711111111 * 1000).toISOString(),
    name: "Sample Model",
    attachments: [{ kind: "image", url: "/uploads/demo.png" }],
    source: "",
    type: "text",
    automationKind: null,
  });
});

test("mapLunariaMessageToDisplayMessage collapses automation user prompts into a screenshot note", () => {
  const message = {
    id: "msg_automation_user",
    role: "user",
    text: "请观察当前屏幕并主动说话",
    source: "automation",
    createdAt: 1711112222,
    attachments: [{ kind: "image", url: "/uploads/capture.png" }],
  };

  assert.deepEqual(mapLunariaMessageToDisplayMessage(message), {
    id: "msg_automation_user",
    content: "",
    role: "system",
    timestamp: new Date(1711112222 * 1000).toISOString(),
    name: "",
    attachments: [],
    type: "automation_note",
    source: "automation",
    automationKind: "screenshot",
  });
});

test("mapLunariaMessageToDisplayMessage clears automation assistant labels so the UI can fall back to the model name", () => {
  const message = {
    id: "msg_automation_ai",
    role: "assistant",
    text: "我看到了屏幕上的变化。",
    source: "automation",
    meta: "自动化 · 截图观察",
    createdAt: 1711113333,
  };

  assert.deepEqual(mapLunariaMessageToDisplayMessage(message), {
    id: "msg_automation_ai",
    content: "我看到了屏幕上的变化。",
    role: "ai",
    timestamp: new Date(1711113333 * 1000).toISOString(),
    name: "",
    attachments: [],
    type: "text",
    source: "automation",
    automationKind: null,
  });
});

test("resolveAutomationNoteKind recognizes proactive automation prompts", () => {
  assert.equal(
    resolveAutomationNoteKind({
      role: "user",
      source: "automation",
      attachments: [],
    }),
    "proactive",
  );
});

test("resolveAutomationNoteKind recognizes screenshot automation prompts", () => {
  assert.equal(
    resolveAutomationNoteKind({
      role: "user",
      source: "automation",
      attachments: [{ kind: "image", url: "/uploads/capture.png" }],
    }),
    "screenshot",
  );
});
