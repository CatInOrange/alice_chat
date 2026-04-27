import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { FocusCenterConfig } from "@/domains/types";

interface SettingsState {
  currentProviderId: string;
  providerFieldValues: Record<string, string>;
  providerFieldManifestValues: Record<string, string>;
  ttsEnabled: boolean;
  ttsProvider: string;
  focusCenterByModel: Record<string, FocusCenterConfig>;
  backgroundByMode: Record<"window" | "pet", string>;
  setCurrentProviderId: (value: string) => void;
  setProviderFieldValue: (providerId: string, fieldKey: string, value: string) => void;
  setProviderFieldValues: (value: Record<string, string>) => void;
  setProviderFieldManifestValues: (value: Record<string, string>) => void;
  setTtsEnabled: (value: boolean) => void;
  setTtsProvider: (value: string) => void;
  setFocusCenterForModel: (modelId: string, value: FocusCenterConfig) => void;
  setBackgroundForMode: (mode: "window" | "pet", value: string) => void;
}

export const useSettingsStore = create<SettingsState>()(
  persist(
    (set) => ({
      currentProviderId: "",
      providerFieldValues: {},
      providerFieldManifestValues: {},
      ttsEnabled: true,
      ttsProvider: "",
      focusCenterByModel: {},
      backgroundByMode: {
        window: "",
        pet: "",
      },
      setCurrentProviderId: (value) => set({ currentProviderId: value }),
      setProviderFieldValue: (providerId, fieldKey, value) => set((state) => ({
        providerFieldValues: {
          ...state.providerFieldValues,
          [`${providerId}.${fieldKey}`]: value,
        },
      })),
      setProviderFieldValues: (value) => set({ providerFieldValues: value }),
      setProviderFieldManifestValues: (value) => set({ providerFieldManifestValues: value }),
      setTtsEnabled: (value) => set({ ttsEnabled: value }),
      setTtsProvider: (value) => set({ ttsProvider: value }),
      setFocusCenterForModel: (modelId, value) => set((state) => ({
        focusCenterByModel: {
          ...state.focusCenterByModel,
          [modelId]: {
            ...state.focusCenterByModel[modelId],
            ...value,
          },
        },
      })),
      setBackgroundForMode: (mode, value) => set((state) => ({
        backgroundByMode: {
          ...state.backgroundByMode,
          [mode]: value,
        },
      })),
    }),
    {
      name: "lunaria-settings-store-v1",
      storage: createJSONStorage(() => localStorage),
      partialize: (state) => ({
        currentProviderId: state.currentProviderId,
        providerFieldValues: state.providerFieldValues,
        providerFieldManifestValues: state.providerFieldManifestValues,
        ttsEnabled: state.ttsEnabled,
        ttsProvider: state.ttsProvider,
        focusCenterByModel: state.focusCenterByModel,
        backgroundByMode: state.backgroundByMode,
      }),
    },
  ),
);
