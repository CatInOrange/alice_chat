import test from "node:test";
import assert from "node:assert/strict";

import { buildStoredModelInfo } from "../live2d-config-utils.ts";

test("buildStoredModelInfo preserves previous pointerInteractive and scrollToResize when omitted", () => {
  const result = buildStoredModelInfo(
    {
      pointerInteractive: false,
      scrollToResize: false,
    },
    {
      name: "Hiyori",
      url: "/models/hiyori.model3.json",
      kScale: 0.5,
      initialXshift: 0,
      initialYshift: 0,
      emotionMap: {},
    },
  );

  assert.equal(result.pointerInteractive, false);
  assert.equal(result.scrollToResize, false);
  assert.equal(result.kScale, 1);
});

test("buildStoredModelInfo clears model info when url is missing", () => {
  const result = buildStoredModelInfo(
    {
      pointerInteractive: true,
      scrollToResize: true,
    },
    undefined,
  );

  assert.equal(result, undefined);
});
