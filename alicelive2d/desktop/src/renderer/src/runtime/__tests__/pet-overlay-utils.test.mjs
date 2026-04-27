import test from "node:test";
import assert from "node:assert/strict";

import {
  getPetOverlayCenter,
  getPetShellBackgroundStyle,
} from "../pet-overlay-utils.ts";

test("getPetOverlayCenter returns the center of the active work area in overlay coordinates", () => {
  assert.deepEqual(
    getPetOverlayCenter({
      workArea: { x: 1920, y: 0, width: 2560, height: 1440 },
      virtualBounds: { x: 0, y: 0, width: 4480, height: 1440 },
    }),
    {
      x: 3200,
      y: 720,
    },
  );
});

test("getPetOverlayCenter compensates for negative virtual screen origins", () => {
  assert.deepEqual(
    getPetOverlayCenter({
      workArea: { x: 0, y: 23, width: 1728, height: 1080 },
      virtualBounds: { x: -1728, y: 0, width: 3456, height: 1440 },
    }),
    {
      x: 2592,
      y: 563,
    },
  );
});

test("getPetShellBackgroundStyle keeps pet mode transparent when no custom background is configured", () => {
  assert.deepEqual(
    getPetShellBackgroundStyle(""),
    {},
  );
});

test("getPetShellBackgroundStyle applies the image overlay only when a custom pet background exists", () => {
  assert.deepEqual(
    getPetShellBackgroundStyle("https://example.com/bg.png"),
    {
      backgroundImage: "linear-gradient(rgba(251,247,243,0.18), rgba(244,236,228,0.5)), url(https://example.com/bg.png)",
      backgroundSize: "cover",
      backgroundPosition: "center",
    },
  );
});
