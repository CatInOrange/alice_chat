export function scheduleLive2DInitialization({
  currentTimer,
  delayMs = 500,
  clearTimeoutImpl = clearTimeout,
  setTimeoutImpl = setTimeout,
  onInitialize,
}) {
  if (currentTimer != null) {
    clearTimeoutImpl(currentTimer);
  }

  return setTimeoutImpl(onInitialize, delayMs);
}

export function cancelScheduledLive2DInitialization({
  currentTimer,
  clearTimeoutImpl = clearTimeout,
}) {
  if (currentTimer != null) {
    clearTimeoutImpl(currentTimer);
  }

  return null;
}
