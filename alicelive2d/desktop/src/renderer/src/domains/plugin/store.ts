import { create } from "zustand";
import { PluginCatalogItem } from "@/domains/types";

interface PluginState {
  plugins: PluginCatalogItem[];
  pluginLoadState: "idle" | "loading" | "ready" | "error";
  pluginLogs: string[];
  setPlugins: (items: PluginCatalogItem[]) => void;
  setPluginLoadState: (value: PluginState["pluginLoadState"]) => void;
  appendPluginLog: (value: string) => void;
  clearPluginLogs: () => void;
}

export const usePluginStore = create<PluginState>((set) => ({
  plugins: [],
  pluginLoadState: "idle",
  pluginLogs: [],
  setPlugins: (items) => set({ plugins: items }),
  setPluginLoadState: (value) => set({ pluginLoadState: value }),
  appendPluginLog: (value) => set((state) => ({
    pluginLogs: [...state.pluginLogs.slice(-79), value],
  })),
  clearPluginLogs: () => set({ pluginLogs: [] }),
}));
