export function shouldResizeLive2DCanvas({
  width,
  height,
  previousWidth,
  previousHeight,
  sidebarChanged,
  hasAppliedInitialScale,
}) {
  if (width <= 0 || height <= 0) {
    return false;
  }

  if (!hasAppliedInitialScale) {
    return true;
  }

  const dimensionsChanged = Math.abs(previousWidth - width) > 1
    || Math.abs(previousHeight - height) > 1;

  return dimensionsChanged || sidebarChanged;
}
