export function getComposerAction({
  hasContent,
  isStreaming,
}) {
  if (isStreaming) {
    return "interrupt";
  }

  if (!hasContent) {
    return "noop";
  }

  return "send";
}

export function resolveAutomationNoteKind(message) {
  const role = String(message?.role || "").toLowerCase();
  const source = String(message?.source || "").toLowerCase();
  if (role !== "user" || source !== "automation") {
    return null;
  }

  return Array.isArray(message?.attachments) && message.attachments.length
    ? "screenshot"
    : "proactive";
}

export function mapLunariaMessageToDisplayMessage(message) {
  const normalizedRole = String(message?.role || "").toLowerCase();
  const normalizedSource = String(message?.source || "").toLowerCase();
  const automationKind = resolveAutomationNoteKind(message);

  if (automationKind) {
    return {
      id: String(message?.id || ""),
      content: "",
      role: "system",
      timestamp: new Date(Number(message?.createdAt || 0) * 1000).toISOString(),
      name: "",
      attachments: [],
      type: "automation_note",
      source: normalizedSource,
      automationKind,
    };
  }

  return {
    id: String(message?.id || ""),
    content: String(message?.text || ""),
    role: normalizedRole === "assistant"
      ? "ai"
      : normalizedRole === "system"
        ? "system"
        : "human",
    timestamp: new Date(Number(message?.createdAt || 0) * 1000).toISOString(),
    name: normalizedRole === "assistant" && normalizedSource === "automation"
      ? ""
      : String(message?.meta || ""),
    attachments: Array.isArray(message?.attachments) ? message.attachments : [],
    source: normalizedSource,
    type: "text",
    automationKind: null,
  };
}
