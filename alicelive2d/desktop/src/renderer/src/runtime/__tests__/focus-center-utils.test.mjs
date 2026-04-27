import test from "node:test";
import assert from "node:assert/strict";

import { resolveFocusCenterConfig } from "../focus-center-utils.ts";

function buildManifest() {
  return {
    selectedModelId: "sample-model",
    live2d: {
      focusCenter: {
        enabled: true,
        headRatio: 0.25,
      },
    },
    model: {
      id: "sample-model",
      live2d: {
        focusCenter: {
          enabled: true,
          headRatio: 0.33,
        },
      },
    },
  };
}

test("resolveFocusCenterConfig falls back to manifest defaults when no stored value exists", () => {
  assert.deepEqual(
    resolveFocusCenterConfig({
      manifest: buildManifest(),
      focusCenterByModel: {},
      modelId: "sample-model",
    }),
    {
      enabled: true,
      headRatio: 0.33,
    },
  );
});

test("resolveFocusCenterConfig preserves stored values over manifest defaults", () => {
  assert.deepEqual(
    resolveFocusCenterConfig({
      manifest: buildManifest(),
      focusCenterByModel: {
        "sample-model": {
          enabled: false,
          headRatio: 0.61,
        },
      },
      modelId: "sample-model",
    }),
    {
      enabled: false,
      headRatio: 0.61,
    },
  );
});
