export function getNextWindowSidebarPanel(currentPanel, requestedPanel) {
  if (!requestedPanel) {
    return null;
  }

  return currentPanel === requestedPanel ? null : requestedPanel;
}

export function shouldShowWindowSidebarSection(activePanel, section) {
  return activePanel === section;
}

export function shouldResizeWindowLive2DForSidebar(activePanel) {
  return activePanel !== null;
}

export function getWindowLive2DFrameStyle({ isElectron, sidebarWidth }) {
  return {
    top: isElectron ? "30px" : "0",
    left: "0",
    right: `${sidebarWidth}px`,
    bottom: "0",
  };
}

export function getLunariaDocumentBackground({ mode, hasBackground, transparentWindow = false }) {
  if (mode === "pet") {
    return "transparent";
  }

  if (transparentWindow) {
    return "transparent";
  }

  return hasBackground ? "#fbf7f3" : "#f6efe8";
}
