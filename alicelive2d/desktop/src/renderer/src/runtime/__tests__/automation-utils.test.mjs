import test from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_AUTOMATION_CONFIG,
  normalizeAutomationConfig,
  shouldRunAutomationRule,
} from "../automation-utils.ts";

test("normalizeAutomationConfig merges defaults and clamps numeric values", () => {
  const config = normalizeAutomationConfig({
    enabled: true,
    proactive: {
      intervalMin: -3,
      prompt: "  ping  ",
    },
    screenshot: {
      intervalMin: 5000,
    },
    music: {
      volume: 8,
      loop: true,
    },
  });

  assert.equal(config.enabled, true);
  assert.equal(config.onlyPetMode, DEFAULT_AUTOMATION_CONFIG.onlyPetMode);
  assert.equal(config.proactive.intervalMin, 1);
  assert.equal(config.proactive.prompt, "ping");
  assert.equal(config.screenshot.intervalMin, 1440);
  assert.equal(config.music.volume, 1);
  assert.equal(config.music.loop, true);
});

test("shouldRunAutomationRule respects enable flags, mode, running state and interval", () => {
  const config = normalizeAutomationConfig({
    enabled: true,
    onlyPetMode: true,
    proactive: {
      enabled: true,
      intervalMin: 10,
    },
  });

  assert.equal(
    shouldRunAutomationRule({
      config,
      ruleKey: "proactive",
      mode: "window",
      ruleState: { lastRunAt: 0, running: false },
      now: 1000,
    }),
    false,
  );

  assert.equal(
    shouldRunAutomationRule({
      config,
      ruleKey: "proactive",
      mode: "pet",
      ruleState: { lastRunAt: Date.now(), running: false },
      now: Date.now(),
    }),
    false,
  );

  assert.equal(
    shouldRunAutomationRule({
      config,
      ruleKey: "proactive",
      mode: "pet",
      ruleState: { lastRunAt: 0, running: true },
      now: 1000,
    }),
    false,
  );

  assert.equal(
    shouldRunAutomationRule({
      config,
      ruleKey: "proactive",
      mode: "pet",
      ruleState: { lastRunAt: 0, running: false },
      now: 10 * 60 * 1000,
    }),
    true,
  );
});
