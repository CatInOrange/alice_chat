import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { ConnectionState, LunariaSession } from "@/domains/types";
import { getSessionStoreUpdateForBackendUrl } from "@/runtime/session-store-utils.ts";

interface SessionState {
  backendUrl: string;
  sessions: LunariaSession[];
  currentSessionId: string | null;
  connectionState: ConnectionState;
  lastEventSeq: number;
  setBackendUrl: (value: string) => void;
  setSessions: (sessions: LunariaSession[]) => void;
  setCurrentSessionId: (sessionId: string | null) => void;
  setConnectionState: (value: ConnectionState) => void;
  setLastEventSeq: (value: number) => void;
}

export const useSessionStore = create<SessionState>()(
  persist(
    (set) => ({
      backendUrl: "",  // 空字符串会让前端使用当前页面 origin 作为 API 基础地址
      sessions: [],
      currentSessionId: null,
      connectionState: "idle",
      lastEventSeq: 0,
      setBackendUrl: (value) => set((state) => (
        getSessionStoreUpdateForBackendUrl({
          currentBackendUrl: state.backendUrl,
          currentLastEventSeq: state.lastEventSeq,
          nextBackendUrl: value,
        })
      )),
      setSessions: (sessions) => set({ sessions }),
      setCurrentSessionId: (sessionId) => set({ currentSessionId: sessionId }),
      setConnectionState: (value) => set({ connectionState: value }),
      setLastEventSeq: (value) => set({ lastEventSeq: value }),
    }),
    {
      name: "lunaria-session-store-v1",
      storage: createJSONStorage(() => localStorage),
      partialize: (state) => ({
        backendUrl: state.backendUrl,
        lastEventSeq: state.lastEventSeq,
      }),
    },
  ),
);
