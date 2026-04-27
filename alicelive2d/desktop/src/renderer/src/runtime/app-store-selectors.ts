const EMPTY_MESSAGES = Object.freeze([]);

export function selectCurrentSessionMessages(state) {
  const sessionId = state.currentSessionId;
  if (!sessionId) {
    return EMPTY_MESSAGES;
  }

  return state.messagesBySession[sessionId] || EMPTY_MESSAGES;
}
