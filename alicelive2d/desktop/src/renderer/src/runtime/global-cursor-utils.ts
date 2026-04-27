export function shouldUseGlobalCursorTracking({ mode, focusCenter }) {
  return mode === "pet" && focusCenter?.enabled !== false;
}

export function toRendererPointerFromScreenPoint({ screenPoint, virtualBounds }) {
  if (
    !screenPoint
    || !Number.isFinite(Number(screenPoint.x))
    || !Number.isFinite(Number(screenPoint.y))
  ) {
    return null;
  }

  const originX = Number(virtualBounds?.x ?? 0);
  const originY = Number(virtualBounds?.y ?? 0);

  return {
    x: Number(screenPoint.x) - originX,
    y: Number(screenPoint.y) - originY,
  };
}
