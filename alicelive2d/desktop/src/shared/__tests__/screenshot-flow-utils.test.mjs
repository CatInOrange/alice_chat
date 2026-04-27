import test from "node:test";
import assert from "node:assert/strict";

import {
  getCaptureSourceForDisplay,
  getCaptureResizeTarget,
  getDisplayForScreenshotSession,
  getPetModeAlwaysOnTopLevel,
  getScreenshotCapturePlan,
  getScreenshotCaptureOutputConfig,
  getScreenshotRestoreWindowConfig,
  getScreenshotSelectionBounds,
} from "../screenshot-flow-utils.mjs";

test("getCaptureResizeTarget preserves source resolution by default", () => {
  assert.deepEqual(
    getCaptureResizeTarget({ width: 3840, height: 2160 }),
    { width: 3840, height: 2160 },
  );
});

test("getCaptureResizeTarget leaves already-small captures untouched", () => {
  assert.deepEqual(
    getCaptureResizeTarget({ width: 1280, height: 720 }),
    { width: 1280, height: 720 },
  );
});

test("getCaptureResizeTarget can still honor an explicit size budget", () => {
  assert.deepEqual(
    getCaptureResizeTarget({
      width: 3840,
      height: 2160,
      maxWidth: 1920,
      maxPixels: 1920 * 1080,
    }),
    { width: 1920, height: 1080 },
  );
});

test("getPetModeAlwaysOnTopLevel avoids the screen-saver layer", () => {
  assert.equal(getPetModeAlwaysOnTopLevel(), "floating");
});

test("getScreenshotSelectionBounds mirrors the active display bounds", () => {
  assert.deepEqual(
    getScreenshotSelectionBounds({
      x: -1440,
      y: 0,
      width: 1440,
      height: 900,
    }),
    {
      x: -1440,
      y: 0,
      width: 1440,
      height: 900,
    },
  );
});

test("getDisplayForScreenshotSession chooses the display under the cursor", () => {
  const displays = [
    { id: "left", bounds: { x: -1440, y: 0, width: 1440, height: 900 } },
    { id: "right", bounds: { x: 0, y: 0, width: 1920, height: 1080 } },
  ];

  assert.deepEqual(
    getDisplayForScreenshotSession({
      displays,
      cursorPoint: { x: -200, y: 300 },
    }),
    displays[0],
  );
});

test("getScreenshotRestoreWindowConfig restores pet mode click-through when nothing is hovered", () => {
  assert.deepEqual(
    getScreenshotRestoreWindowConfig({
      mode: "pet",
      forceIgnoreMouse: false,
      hoveringComponentCount: 0,
    }),
    {
      alwaysOnTop: true,
      alwaysOnTopLevel: "floating",
      focusable: false,
      ignoreMouseEvents: true,
      moveTopAfterShow: true,
      resizable: false,
      skipTaskbar: true,
    },
  );
});

test("getScreenshotRestoreWindowConfig keeps pet mode interactive when the shell is hovered", () => {
  assert.deepEqual(
    getScreenshotRestoreWindowConfig({
      mode: "pet",
      forceIgnoreMouse: false,
      hoveringComponentCount: 1,
    }),
    {
      alwaysOnTop: true,
      alwaysOnTopLevel: "floating",
      focusable: true,
      ignoreMouseEvents: false,
      moveTopAfterShow: true,
      resizable: false,
      skipTaskbar: true,
    },
  );
});

test("getScreenshotCaptureOutputConfig uses JPEG for selection captures", () => {
  assert.deepEqual(
    getScreenshotCaptureOutputConfig({ purpose: "selection" }),
    {
      filename: "screen-capture.jpg",
      jpegQuality: 92,
      maxPixels: 1920 * 1080,
      maxWidth: 1920,
      mimeType: "image/jpeg",
    },
  );
});

test("getScreenshotCaptureOutputConfig uses JPEG for full-screen overlay attachments", () => {
  assert.deepEqual(
    getScreenshotCaptureOutputConfig({ purpose: "selection-attachment" }),
    {
      filename: "screen-capture.jpg",
      jpegQuality: 92,
      maxPixels: 1920 * 1080,
      maxWidth: 1920,
      mimeType: "image/jpeg",
    },
  );
});

test("getScreenshotCapturePlan constrains selection previews before the window is restored", () => {
  assert.deepEqual(
    getScreenshotCapturePlan({
      displaySize: { width: 3840, height: 2160 },
      scaleFactor: 2,
      purpose: "selection",
    }),
    {
      captureSize: { width: 1920, height: 1080 },
      outputConfig: {
        filename: "screen-capture.jpg",
        jpegQuality: 92,
        maxPixels: 1920 * 1080,
        maxWidth: 1920,
        mimeType: "image/jpeg",
      },
      sourceSize: { width: 7680, height: 4320 },
    },
  );
});

test("getScreenshotCapturePlan keeps full-size captures for direct attachments", () => {
  assert.deepEqual(
    getScreenshotCapturePlan({
      displaySize: { width: 3840, height: 2160 },
      scaleFactor: 2,
      purpose: "attachment",
    }).captureSize,
    { width: 7680, height: 4320 },
  );
});

test("getCaptureSourceForDisplay prefers an exact display_id match", () => {
  const exact = {
    id: "screen:2:0",
    display_id: "222",
    thumbnail: { getSize: () => ({ width: 2560, height: 1600 }) },
  };

  assert.equal(
    getCaptureSourceForDisplay({
      sources: [
        {
          id: "screen:1:0",
          display_id: "111",
          thumbnail: { getSize: () => ({ width: 1920, height: 1080 }) },
        },
        exact,
      ],
      targetDisplay: { id: "222" },
      targetSize: { width: 2560, height: 1600 },
    }),
    exact,
  );
});

test("getCaptureSourceForDisplay falls back to the closest aspect ratio and size", () => {
  const wide = {
    id: "screen:1:0",
    display_id: "",
    thumbnail: { getSize: () => ({ width: 1920, height: 1080 }) },
  };
  const tall = {
    id: "screen:2:0",
    display_id: "",
    thumbnail: { getSize: () => ({ width: 2560, height: 1600 }) },
  };

  assert.equal(
    getCaptureSourceForDisplay({
      sources: [wide, tall],
      targetDisplay: { id: "missing-display-id" },
      targetSize: { width: 2560, height: 1600 },
    }),
    tall,
  );
});
