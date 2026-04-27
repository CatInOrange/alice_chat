export function resolveActiveLive2DCanvas({
  currentCanvas,
  nextCanvas,
}) {
  if (!nextCanvas) {
    return currentCanvas || null;
  }

  if (!currentCanvas || currentCanvas.isConnected === false) {
    return nextCanvas;
  }

  return currentCanvas;
}
