import test from "node:test";
import assert from "node:assert/strict";

import { getPetToggleButtonState } from "../pet-shell-display-utils.ts";

test("getPetToggleButtonState keeps the hidden pet toggle icon-only", () => {
  assert.deepEqual(getPetToggleButtonState("hidden"), {
    ariaLabel: "打开对话",
    showText: false,
  });
});

test("getPetToggleButtonState keeps the expanded pet toggle icon-only while updating aria text", () => {
  assert.deepEqual(getPetToggleButtonState("chat"), {
    ariaLabel: "隐藏对话",
    showText: false,
  });
});
