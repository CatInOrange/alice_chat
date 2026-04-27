import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { normalizeAutomationConfig } from "@/runtime/automation-utils.ts";
import { AutomationConfig, AutomationLogItem, AutomationRuleConfig, AutomationRuleState, AutomationMusicConfig } from "@/domains/types";

interface AutomationState {
  automation: AutomationConfig;
  automationRuleState: Record<"proactive" | "screenshot", AutomationRuleState>;
  automationLogs: AutomationLogItem[];
  setAutomationConfig: (value: Partial<AutomationConfig>) => void;
  setAutomationRuleConfig: (rule: "proactive" | "screenshot", value: Partial<AutomationRuleConfig>) => void;
  setAutomationMusicConfig: (value: Partial<AutomationMusicConfig>) => void;
  setAutomationRuleState: (rule: "proactive" | "screenshot", value: Partial<AutomationRuleState>) => void;
  appendAutomationLog: (text: string, status?: AutomationLogItem["status"], timestamp?: number) => void;
  clearAutomationLogs: () => void;
}

export const useAutomationStore = create<AutomationState>()(
  persist(
    (set) => ({
      automation: normalizeAutomationConfig({}) as AutomationConfig,
      automationRuleState: {
        proactive: { lastRunAt: 0, running: false },
        screenshot: { lastRunAt: 0, running: false },
      },
      automationLogs: [],
      setAutomationConfig: (value) => set((state) => ({
        automation: normalizeAutomationConfig({
          ...state.automation,
          ...value,
        }) as AutomationConfig,
      })),
      setAutomationRuleConfig: (rule, value) => set((state) => ({
        automation: normalizeAutomationConfig({
          ...state.automation,
          [rule]: {
            ...state.automation[rule],
            ...value,
          },
        }) as AutomationConfig,
      })),
      setAutomationMusicConfig: (value) => set((state) => ({
        automation: normalizeAutomationConfig({
          ...state.automation,
          music: {
            ...state.automation.music,
            ...value,
          },
        }) as AutomationConfig,
      })),
      setAutomationRuleState: (rule, value) => set((state) => ({
        automationRuleState: {
          ...state.automationRuleState,
          [rule]: {
            ...state.automationRuleState[rule],
            ...value,
          },
        },
      })),
      appendAutomationLog: (text, status = "info", timestamp = Date.now()) => set((state) => ({
        automationLogs: [
          ...state.automationLogs.slice(-23),
          {
            id: `auto_log_${timestamp}_${Math.random().toString(36).slice(2, 8)}`,
            timestamp,
            timeLabel: new Date(timestamp).toLocaleTimeString("zh-CN", {
              hour: "2-digit",
              minute: "2-digit",
              second: "2-digit",
            }),
            text: String(text || ""),
            status,
          },
        ],
      })),
      clearAutomationLogs: () => set({ automationLogs: [] }),
    }),
    {
      name: "lunaria-automation-store-v1",
      storage: createJSONStorage(() => localStorage),
      partialize: (state) => ({
        automation: state.automation,
      }),
    },
  ),
);
