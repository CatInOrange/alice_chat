import { create } from "zustand";
import { getManifestHydrationState } from "@/runtime/manifest-hydration-utils.ts";
import {
  FocusCenterConfig,
  LunariaExpression,
  LunariaManifest,
  LunariaMotion,
  LunariaQuickAction,
  PersistentToggleConfig,
  RuntimeRect,
} from "@/domains/types";

interface ModelState {
  manifest: LunariaManifest | null;
  quickActions: LunariaQuickAction[];
  motions: LunariaMotion[];
  expressions: LunariaExpression[];
  persistentToggles: Record<string, PersistentToggleConfig>;
  persistentToggleState: Record<string, boolean>;
  currentModelBounds: RuntimeRect | null;
  hydrateManifest: (manifest: LunariaManifest | null) => void;
  setManifest: (value: LunariaManifest | null) => void;
  togglePersistentToggle: (key: string) => void;
  setPersistentToggle: (key: string, value: boolean) => void;
  setCurrentModelBounds: (value: RuntimeRect | null) => void;
}

export const useModelStore = create<ModelState>((set) => ({
  manifest: null,
  quickActions: [],
  motions: [],
  expressions: [],
  persistentToggles: {},
  persistentToggleState: {},
  currentModelBounds: null,
  setManifest: (value) => set({ manifest: value }),
  hydrateManifest: (manifest) => set((state) => getManifestHydrationState({
    state: {
      currentProviderId: "",
      ttsEnabled: true,
      ttsProvider: "",
      focusCenterByModel: {} as Record<string, FocusCenterConfig>,
      ...state,
    },
    manifest,
  }) as Partial<ModelState> & { manifest: LunariaManifest | null }),
  togglePersistentToggle: (key) => set((state) => ({
    persistentToggleState: {
      ...state.persistentToggleState,
      [key]: !state.persistentToggleState[key],
    },
  })),
  setPersistentToggle: (key, value) => set((state) => ({
    persistentToggleState: {
      ...state.persistentToggleState,
      [key]: value,
    },
  })),
  setCurrentModelBounds: (value) => set({ currentModelBounds: value }),
}));

export function getQuickActionLabel(action: LunariaQuickAction): string {
  return String(action.label || action.id || action.type || "Action");
}
