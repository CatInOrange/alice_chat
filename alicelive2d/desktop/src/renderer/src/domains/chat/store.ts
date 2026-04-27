import { create } from "zustand";
import { LunariaMessage, StreamingMessage } from "@/domains/types";
import {
  reconcileSessionMessages,
  resolveCommittedChatState,
} from "@/runtime/chat-runtime-utils.ts";

interface ChatState {
  messagesBySession: Record<string, LunariaMessage[]>;
  streamingMessage: StreamingMessage | null;
  setMessagesForSession: (sessionId: string, messages: LunariaMessage[]) => void;
  commitMessagesForSession: (sessionId: string, messages: LunariaMessage[]) => void;
  appendMessageForSession: (sessionId: string, message: LunariaMessage) => void;
  upsertMessageForSession: (sessionId: string, message: LunariaMessage) => void;
  setStreamingMessage: (message: StreamingMessage | null) => void;
}

const emptyMessages: LunariaMessage[] = [];

function upsertMessage(existing: LunariaMessage[], nextMessage: LunariaMessage): LunariaMessage[] {
  const index = existing.findIndex((item) => item.id === nextMessage.id);
  if (index === -1) {
    return [...existing, nextMessage];
  }

  const clone = [...existing];
  clone[index] = nextMessage;
  return clone;
}

export const useChatStore = create<ChatState>((set) => ({
  messagesBySession: {},
  streamingMessage: null,
  setMessagesForSession: (sessionId, messages) => set((state) => ({
    messagesBySession: {
      ...state.messagesBySession,
      [sessionId]: reconcileSessionMessages(state.messagesBySession[sessionId] || [], messages),
    },
  })),
  commitMessagesForSession: (sessionId, messages) => set((state) => (
    resolveCommittedChatState({
      messagesBySession: state.messagesBySession,
      streamingMessage: state.streamingMessage,
      sessionId,
      messages,
    })
  )),
  appendMessageForSession: (sessionId, message) => set((state) => ({
    messagesBySession: {
      ...state.messagesBySession,
      [sessionId]: [...(state.messagesBySession[sessionId] || []), message],
    },
  })),
  upsertMessageForSession: (sessionId, message) => set((state) => ({
    messagesBySession: {
      ...state.messagesBySession,
      [sessionId]: upsertMessage(state.messagesBySession[sessionId] || [], message),
    },
  })),
  setStreamingMessage: (message) => set({ streamingMessage: message }),
}));

export function selectCurrentSessionMessages(state: ChatState, currentSessionId: string | null): LunariaMessage[] {
  if (!currentSessionId) {
    return emptyMessages;
  }

  return state.messagesBySession[currentSessionId] || emptyMessages;
}
