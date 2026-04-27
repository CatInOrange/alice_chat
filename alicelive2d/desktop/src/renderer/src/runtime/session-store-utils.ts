export function getSessionStoreUpdateForBackendUrl({
  currentBackendUrl,
  currentLastEventSeq,
  nextBackendUrl,
}) {
  const backendUrl = String(nextBackendUrl || "");
  return {
    backendUrl,
    lastEventSeq: backendUrl === String(currentBackendUrl || "")
      ? Number(currentLastEventSeq || 0)
      : 0,
  };
}
