export function shouldSpeakRealtimeMessage(incoming, currentSessionId, isRealtimeEvent = true) {
  if (!isRealtimeEvent) {
    return false;
  }

  if (!incoming?.sessionId || incoming.sessionId !== currentSessionId) {
    return false;
  }

  return incoming.source === "push";
}

export function shouldFocusRealtimeSession(incoming, currentSessionId, isRealtimeEvent = true) {
  if (!isRealtimeEvent) {
    return false;
  }

  if (!incoming?.sessionId) {
    return false;
  }

  if (incoming.source !== "push") {
    return false;
  }

  return incoming.sessionId !== currentSessionId;
}

export function createNextPlaybackVersion(currentVersion = 0) {
  return Number(currentVersion || 0) + 1;
}

export function isPlaybackVersionCurrent(expectedVersion, activeVersion) {
  return Number(expectedVersion || 0) === Number(activeVersion || 0);
}
