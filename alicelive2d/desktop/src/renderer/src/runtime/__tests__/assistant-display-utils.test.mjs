import test from "node:test";
import assert from "node:assert/strict";

import { resolveAssistantDisplayName } from "../assistant-display-utils.ts";

test("resolveAssistantDisplayName prefers the configured character name", () => {
  assert.equal(
    resolveAssistantDisplayName({
      configName: "Sample Model",
      manifestName: "Lunaria",
      fallbackName: "Assistant",
    }),
    "Sample Model",
  );
});

test("resolveAssistantDisplayName falls back to the manifest model name when the config name is empty", () => {
  assert.equal(
    resolveAssistantDisplayName({
      configName: "   ",
      manifestName: "Mira",
      fallbackName: "Assistant",
    }),
    "Mira",
  );
});

test("resolveAssistantDisplayName returns the fallback when neither model name is available", () => {
  assert.equal(
    resolveAssistantDisplayName({
      configName: "",
      manifestName: "",
      fallbackName: "Assistant",
    }),
    "Assistant",
  );
});
