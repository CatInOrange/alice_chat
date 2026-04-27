export function toPositiveRect(start, end) {
  const left = Math.min(Number(start?.x || 0), Number(end?.x || 0));
  const top = Math.min(Number(start?.y || 0), Number(end?.y || 0));
  const right = Math.max(Number(start?.x || 0), Number(end?.x || 0));
  const bottom = Math.max(Number(start?.y || 0), Number(end?.y || 0));

  return {
    x: left,
    y: top,
    width: Math.max(0, right - left),
    height: Math.max(0, bottom - top),
  };
}

export function clampSelectionRect(rect, bounds) {
  const x = Math.max(0, Number(rect?.x || 0));
  const y = Math.max(0, Number(rect?.y || 0));
  const maxWidth = Math.max(0, Number(bounds?.width || 0) - x);
  const maxHeight = Math.max(0, Number(bounds?.height || 0) - y);

  return {
    x,
    y,
    width: Math.max(0, Math.min(Number(rect?.width || 0), maxWidth)),
    height: Math.max(0, Math.min(Number(rect?.height || 0), maxHeight)),
  };
}

export function createFullScreenSelection(bounds) {
  return clampSelectionRect(
    {
      x: 0,
      y: 0,
      width: Math.max(0, Number(bounds?.width || 0)),
      height: Math.max(0, Number(bounds?.height || 0)),
    },
    bounds,
  );
}

export function selectionCoversBounds(rect, bounds) {
  const normalized = clampSelectionRect(rect, bounds);
  const safeWidth = Math.max(0, Number(bounds?.width || 0));
  const safeHeight = Math.max(0, Number(bounds?.height || 0));

  return (
    normalized.x === 0
    && normalized.y === 0
    && normalized.width === safeWidth
    && normalized.height === safeHeight
  );
}

export function hasMeaningfulSelection(rect, minSize = 18) {
  return Number(rect?.width || 0) >= minSize && Number(rect?.height || 0) >= minSize;
}
