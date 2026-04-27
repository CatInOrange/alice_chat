export function getConnectionStateAfterChatError(error) {
  return error?.name === "AbortError" ? "idle" : "error";
}

function normalizeAttachmentKey(attachment) {
  return [
    String(attachment?.mimeType || ""),
    String(attachment?.url || ""),
    String(attachment?.data || ""),
  ].join("|");
}

function getMessageReconciliationKey(message) {
  const attachments = Array.isArray(message?.attachments) ? message.attachments : [];
  return [
    String(message?.role || ""),
    String(message?.text || ""),
    String(message?.rawText || ""),
    String(message?.source || ""),
    String(message?.meta || ""),
    attachments.map(normalizeAttachmentKey).join("::"),
  ].join("||");
}

export function reconcileSessionMessages(existingMessages, nextMessages) {
  const buckets = new Map();

  for (const message of Array.isArray(existingMessages) ? existingMessages : []) {
    const key = getMessageReconciliationKey(message);
    const bucket = buckets.get(key) || [];
    bucket.push(message);
    buckets.set(key, bucket);
  }

  return (Array.isArray(nextMessages) ? nextMessages : []).map((message) => {
    const key = getMessageReconciliationKey(message);
    const bucket = buckets.get(key);
    const matched = bucket?.shift();
    if (!matched || !matched.id || matched.id === message.id) {
      return message;
    }

    return {
      ...message,
      id: matched.id,
    };
  });
}

export function resolveCommittedChatState({
  messagesBySession,
  streamingMessage,
  sessionId,
  messages,
}) {
  return {
    messagesBySession: {
      ...messagesBySession,
      [sessionId]: reconcileSessionMessages(messagesBySession[sessionId] || [], messages),
    },
    streamingMessage: streamingMessage?.sessionId === sessionId ? null : streamingMessage,
  };
}
