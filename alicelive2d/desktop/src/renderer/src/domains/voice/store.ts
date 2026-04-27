import { create } from "zustand";

export const enum AiStateEnum {
  IDLE = "idle",
  THINKING_SPEAKING = "thinking-speaking",
  INTERRUPTED = "interrupted",
  LOADING = "loading",
  LISTENING = "listening",
  WAITING = "waiting",
}

export type AiState = `${AiStateEnum}`;

interface VoiceState {
  aiState: AiState;
  backendSynthComplete: boolean;
  subtitle: string;
  showSubtitle: boolean;
  forceIgnoreMouse: boolean;
  setAiState: {
    (state: AiState): void;
    (updater: (currentState: AiState) => AiState): void;
  };
  setBackendSynthComplete: (complete: boolean) => void;
  setSubtitle: (value: string) => void;
  setShowSubtitle: (value: boolean) => void;
  setForceIgnoreMouse: (value: boolean) => void;
  resetState: () => void;
}

const initialState: AiState = AiStateEnum.LOADING;

let waitingTimer: ReturnType<typeof setTimeout> | null = null;

export const useVoiceStore = create<VoiceState>((set) => ({
  aiState: initialState,
  backendSynthComplete: false,
  subtitle: "",
  showSubtitle: true,
  forceIgnoreMouse: false,
  setAiState: (nextState) => set((state) => {
    const resolved = typeof nextState === "function"
      ? nextState(state.aiState)
      : nextState;

    if (resolved === AiStateEnum.WAITING) {
      if (state.aiState === AiStateEnum.THINKING_SPEAKING) {
        return state;
      }

      if (waitingTimer) {
        clearTimeout(waitingTimer);
      }

      waitingTimer = setTimeout(() => {
        useVoiceStore.getState().setAiState(AiStateEnum.IDLE);
        waitingTimer = null;
      }, 2000);

      return {
        aiState: resolved,
      };
    }

    if (waitingTimer) {
      clearTimeout(waitingTimer);
      waitingTimer = null;
    }

    return {
      aiState: resolved,
    };
  }),
  setBackendSynthComplete: (complete) => set({ backendSynthComplete: complete }),
  setSubtitle: (value) => set({ subtitle: value }),
  setShowSubtitle: (value) => set({ showSubtitle: value }),
  setForceIgnoreMouse: (value) => set({ forceIgnoreMouse: value }),
  resetState: () => set({ aiState: AiStateEnum.IDLE }),
}));
