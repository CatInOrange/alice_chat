import { create } from "zustand";
import { ScreenshotOverlayState } from "@/domains/types";

interface ShellState {
  stageActionPanelOpen: boolean;
  screenshotOverlay: ScreenshotOverlayState | null;
  setStageActionPanelOpen: (value: boolean) => void;
  setScreenshotOverlay: (value: ScreenshotOverlayState | null) => void;
  clearScreenshotOverlay: () => void;
}

export const useShellStore = create<ShellState>((set) => ({
  stageActionPanelOpen: false,
  screenshotOverlay: null,
  setStageActionPanelOpen: (value) => set({ stageActionPanelOpen: value }),
  setScreenshotOverlay: (value) => set({ screenshotOverlay: value }),
  clearScreenshotOverlay: () => set({ screenshotOverlay: null }),
}));
