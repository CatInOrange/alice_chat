export function buildStoredModelInfo(previousModelInfo, info) {
  if (!info?.url) {
    return undefined;
  }

  return {
    ...info,
    kScale: Number(info.kScale || 0.5) * 2,
    pointerInteractive:
      "pointerInteractive" in info
        ? info.pointerInteractive
        : (previousModelInfo?.pointerInteractive ?? true),
    scrollToResize:
      "scrollToResize" in info
        ? info.scrollToResize
        : (previousModelInfo?.scrollToResize ?? true),
  };
}
