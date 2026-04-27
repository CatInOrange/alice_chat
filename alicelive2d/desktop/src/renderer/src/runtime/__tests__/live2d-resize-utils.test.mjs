import test from "node:test";
import assert from "node:assert/strict";

import { shouldResizeLive2DCanvas } from "../live2d-resize-utils.ts";

test("shouldResizeLive2DCanvas ignores zero-sized containers before the first valid measurement", () => {
  assert.equal(
    shouldResizeLive2DCanvas({
      width: 0,
      height: 0,
      previousWidth: 0,
      previousHeight: 0,
      sidebarChanged: false,
      hasAppliedInitialScale: false,
    }),
    false,
  );
});

test("shouldResizeLive2DCanvas accepts the first non-zero container size", () => {
  assert.equal(
    shouldResizeLive2DCanvas({
      width: 1280,
      height: 720,
      previousWidth: 0,
      previousHeight: 0,
      sidebarChanged: false,
      hasAppliedInitialScale: false,
    }),
    true,
  );
});

test("shouldResizeLive2DCanvas reruns when the container dimensions change", () => {
  assert.equal(
    shouldResizeLive2DCanvas({
      width: 1360,
      height: 768,
      previousWidth: 1280,
      previousHeight: 720,
      sidebarChanged: false,
      hasAppliedInitialScale: true,
    }),
    true,
  );
});

test("shouldResizeLive2DCanvas reruns when a sidebar-driven layout change is requested", () => {
  assert.equal(
    shouldResizeLive2DCanvas({
      width: 1280,
      height: 720,
      previousWidth: 1280,
      previousHeight: 720,
      sidebarChanged: true,
      hasAppliedInitialScale: true,
    }),
    true,
  );
});

test("shouldResizeLive2DCanvas skips redundant updates once a valid size was already applied", () => {
  assert.equal(
    shouldResizeLive2DCanvas({
      width: 1280,
      height: 720,
      previousWidth: 1280,
      previousHeight: 720,
      sidebarChanged: false,
      hasAppliedInitialScale: true,
    }),
    false,
  );
});
