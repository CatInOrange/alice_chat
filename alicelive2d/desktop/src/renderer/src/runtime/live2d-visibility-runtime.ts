import { audioManager } from "@/utils/audio-manager";

type Live2DActiveListener = (active: boolean) => void;

declare global {
  interface Window {
    aliceLive2dSetActive?: (active: boolean) => boolean;
    aliceLive2dSleep?: () => boolean;
    aliceLive2dWake?: () => boolean;
    __aliceLive2dVisibilityRuntimeInitialized__?: boolean;
  }
}

const listeners = new Set<Live2DActiveListener>();

let hostActive = true;
let documentVisible =
  typeof document === "undefined" ? true : document.visibilityState !== "hidden";
let currentActive = hostActive && documentVisible;

function notifyListeners(nextActive: boolean): void {
  listeners.forEach((listener) => {
    try {
      listener(nextActive);
    } catch (error) {
      console.error("[Live2DVisibility] listener failed:", error);
    }
  });
}

function applyResolvedActive(nextActive: boolean): boolean {
  if (currentActive == nextActive) {
    return currentActive;
  }

  const previousActive = currentActive;
  currentActive = nextActive;
  console.log(
    `[Live2DVisibility] active ${previousActive} -> ${currentActive} (host=${hostActive}, document=${documentVisible})`,
  );

  if (!currentActive) {
    console.log("[Live2DVisibility] stopping audio/lip-sync for inactive stage");
    audioManager.stopCurrentAudioAndLipSync();
  }

  notifyListeners(currentActive);
  return currentActive;
}

function resolveActive(): boolean {
  return hostActive && documentVisible;
}

function syncResolvedActive(): boolean {
  return applyResolvedActive(resolveActive());
}

function installVisibilityHooks(): void {
  if (typeof window === "undefined" || typeof document === "undefined") {
    return;
  }
  if (window.__aliceLive2dVisibilityRuntimeInitialized__) {
    return;
  }
  window.__aliceLive2dVisibilityRuntimeInitialized__ = true;

  const handleVisibilityChange = () => {
    documentVisible = document.visibilityState !== "hidden";
    console.log(
      `[Live2DVisibility] document visibility -> ${document.visibilityState}`,
    );
    syncResolvedActive();
  };

  document.addEventListener("visibilitychange", handleVisibilityChange);
  window.addEventListener("pagehide", () => {
    documentVisible = false;
    console.log("[Live2DVisibility] pagehide");
    syncResolvedActive();
  });
  window.addEventListener("pageshow", () => {
    documentVisible = document.visibilityState !== "hidden";
    console.log("[Live2DVisibility] pageshow");
    syncResolvedActive();
  });

  window.aliceLive2dSetActive = (active: boolean) => {
    hostActive = active !== false;
    console.log(`[Live2DVisibility] host setActive(${hostActive})`);
    return syncResolvedActive();
  };
  window.aliceLive2dSleep = () => window.aliceLive2dSetActive?.(false) ?? false;
  window.aliceLive2dWake = () => window.aliceLive2dSetActive?.(true) ?? true;
}

installVisibilityHooks();
syncResolvedActive();

export function isLive2DActive(): boolean {
  return currentActive;
}

export function setLive2DHostActive(active: boolean): boolean {
  hostActive = active !== false;
  return syncResolvedActive();
}

export function subscribeLive2DActive(
  listener: Live2DActiveListener,
): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
