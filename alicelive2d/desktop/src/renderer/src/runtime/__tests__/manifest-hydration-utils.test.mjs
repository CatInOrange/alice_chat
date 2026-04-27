import test from "node:test";
import assert from "node:assert/strict";

import { getManifestHydrationState } from "../manifest-hydration-utils.ts";

function buildManifest() {
  return {
    selectedModelId: "sample-model",
    model: {
      id: "sample-model",
      quickActions: [{ id: "wave" }],
      motions: [{ group: "Idle", index: 0 }],
      expressions: [{ name: "Happy" }],
      persistentToggles: { wings: { paramId: "ParamWingsHide" } },
      live2d: {
        focusCenter: {
          enabled: true,
          headRatio: 0.33,
        },
      },
      chat: {
        defaultProviderId: "live2d-channel",
        providers: [
          { id: "live2d-channel" },
          { id: "openai-compat" },
        ],
        tts: {
          enabled: true,
          provider: "edge-tts",
          providers: [
            { id: "edge-tts" },
            { id: "gpt-sovits" },
          ],
        },
      },
    },
    live2d: {
      focusCenter: {
        enabled: true,
        headRatio: 0.25,
      },
    },
  };
}

test("getManifestHydrationState uses manifest defaults on first hydrate", () => {
  const manifest = buildManifest();
  const result = getManifestHydrationState({
    state: {
      currentProviderId: "",
      ttsEnabled: true,
      ttsProvider: "",
      focusCenterByModel: {},
    },
    manifest,
  });

  assert.equal(result.currentProviderId, "live2d-channel");
  assert.equal(result.ttsEnabled, true);
  assert.equal(result.ttsProvider, "edge-tts");
  assert.deepEqual(result.focusCenterByModel["sample-model"], {
    enabled: true,
    headRatio: 0.33,
  });
});

test("getManifestHydrationState preserves user-selected provider, tts and focus settings", () => {
  const manifest = buildManifest();
  const result = getManifestHydrationState({
    state: {
      currentProviderId: "live2d-channel",
      ttsEnabled: false,
      ttsProvider: "gpt-sovits",
      focusCenterByModel: {
        "sample-model": {
          enabled: false,
          headRatio: 0.61,
        },
      },
    },
    manifest,
  });

  assert.equal(result.currentProviderId, "live2d-channel");
  assert.equal(result.ttsEnabled, false);
  assert.equal(result.ttsProvider, "gpt-sovits");
  assert.deepEqual(result.focusCenterByModel["sample-model"], {
    enabled: false,
    headRatio: 0.61,
  });
});

test("getManifestHydrationState falls back when preserved settings are no longer valid", () => {
  const manifest = buildManifest();
  const result = getManifestHydrationState({
    state: {
      currentProviderId: "missing-provider",
      ttsEnabled: false,
      ttsProvider: "missing-tts",
      focusCenterByModel: {},
    },
    manifest,
  });

  assert.equal(result.currentProviderId, "live2d-channel");
  assert.equal(result.ttsEnabled, false);
  assert.equal(result.ttsProvider, "edge-tts");
});
