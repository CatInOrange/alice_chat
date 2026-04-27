import test from "node:test";
import assert from "node:assert/strict";

import {
  getLunariaDocumentBackground,
  getWindowLive2DFrameStyle,
  getNextWindowSidebarPanel,
  shouldResizeWindowLive2DForSidebar,
  shouldShowWindowSidebarSection,
} from "../window-shell-utils.ts";

test("getNextWindowSidebarPanel keeps the window sidebar closed by default", () => {
  assert.equal(getNextWindowSidebarPanel(null, null), null);
});

test("getNextWindowSidebarPanel opens settings when it is requested from a closed state", () => {
  assert.equal(getNextWindowSidebarPanel(null, "settings"), "settings");
});

test("getNextWindowSidebarPanel opens sessions when it is requested from a closed state", () => {
  assert.equal(getNextWindowSidebarPanel(null, "sessions"), "sessions");
});

test("getNextWindowSidebarPanel closes settings when the same panel is requested again", () => {
  assert.equal(getNextWindowSidebarPanel("settings", "settings"), null);
});

test("getNextWindowSidebarPanel closes sessions when the same panel is requested again", () => {
  assert.equal(getNextWindowSidebarPanel("sessions", "sessions"), null);
});

test("getNextWindowSidebarPanel switches between sessions and settings", () => {
  assert.equal(getNextWindowSidebarPanel("settings", "sessions"), "sessions");
  assert.equal(getNextWindowSidebarPanel("sessions", "settings"), "settings");
});

test("shouldShowWindowSidebarSection keeps optional sections hidden when no panel is active", () => {
  assert.equal(shouldShowWindowSidebarSection(null, "sessions"), false);
  assert.equal(shouldShowWindowSidebarSection(null, "settings"), false);
});

test("shouldShowWindowSidebarSection only shows the matching panel", () => {
  assert.equal(shouldShowWindowSidebarSection("sessions", "sessions"), true);
  assert.equal(shouldShowWindowSidebarSection("sessions", "settings"), false);
  assert.equal(shouldShowWindowSidebarSection("settings", "settings"), true);
  assert.equal(shouldShowWindowSidebarSection("settings", "sessions"), false);
});

test("shouldResizeWindowLive2DForSidebar only enables sidebar-aware resizing when a panel is visible", () => {
  assert.equal(shouldResizeWindowLive2DForSidebar(null), false);
  assert.equal(shouldResizeWindowLive2DForSidebar("sessions"), true);
  assert.equal(shouldResizeWindowLive2DForSidebar("settings"), true);
});

test("getWindowLive2DFrameStyle reserves titlebar and right sidebar space in electron window mode", () => {
  assert.deepEqual(
    getWindowLive2DFrameStyle({ isElectron: true, sidebarWidth: 340 }),
    {
      top: "30px",
      left: "0",
      right: "340px",
      bottom: "0",
    },
  );
});

test("getWindowLive2DFrameStyle fills the full viewport to the left of the right sidebar on web", () => {
  assert.deepEqual(
    getWindowLive2DFrameStyle({ isElectron: false, sidebarWidth: 340 }),
    {
      top: "0",
      left: "0",
      right: "340px",
      bottom: "0",
    },
  );
});

test("getLunariaDocumentBackground keeps pet mode transparent without a background image", () => {
  assert.equal(
    getLunariaDocumentBackground({ mode: "pet", hasBackground: false }),
    "transparent",
  );
});

test("getLunariaDocumentBackground keeps pet mode transparent even when the pet shell renders a custom background", () => {
  assert.equal(
    getLunariaDocumentBackground({ mode: "pet", hasBackground: true }),
    "transparent",
  );
});

test("getLunariaDocumentBackground uses the soft app background for window mode with a custom stage background", () => {
  assert.equal(
    getLunariaDocumentBackground({ mode: "window", hasBackground: true }),
    "#fbf7f3",
  );
});

test("getLunariaDocumentBackground uses the default app background for window mode without a custom stage background", () => {
  assert.equal(
    getLunariaDocumentBackground({ mode: "window", hasBackground: false }),
    "#f6efe8",
  );
});

test("getLunariaDocumentBackground keeps the outer shell transparent for electron window mode", () => {
  assert.equal(
    getLunariaDocumentBackground({ mode: "window", hasBackground: true, transparentWindow: true }),
    "transparent",
  );
  assert.equal(
    getLunariaDocumentBackground({ mode: "window", hasBackground: false, transparentWindow: true }),
    "transparent",
  );
});
