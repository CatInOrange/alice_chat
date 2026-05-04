export function shouldUseGlobalCursorTracking({ mode, focusCenter }) {
  return (mode === "pet" || mode === "window") && focusCenter?.enabled !== false;
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

export function toRendererPointerFromWindowContentPoint({ screenPoint, contentBounds }) {
  if (
    !screenPoint
    || !contentBounds
    || !Number.isFinite(Number(screenPoint.x))
    || !Number.isFinite(Number(screenPoint.y))
    || !Number.isFinite(Number(contentBounds.x))
    || !Number.isFinite(Number(contentBounds.y))
  ) {
    return null;
  }

  return {
    x: Number(screenPoint.x) - Number(contentBounds.x),
    y: Number(screenPoint.y) - Number(contentBounds.y),
  };
}
