function normalizePositiveNumber(value, fallback = 1) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0) {
    return fallback;
  }
  return numeric;
}

export function getCaptureResizeTarget({
  width,
  height,
  maxWidth,
  maxPixels,
} = {}) {
  const sourceWidth = normalizePositiveNumber(width);
  const sourceHeight = normalizePositiveNumber(height);
  const safeMaxWidth = normalizePositiveNumber(maxWidth, sourceWidth);
  const safeMaxPixels = normalizePositiveNumber(maxPixels, sourceWidth * sourceHeight);

  let scale = 1;
  if (sourceWidth > safeMaxWidth) {
    scale = Math.min(scale, safeMaxWidth / sourceWidth);
  }

  const totalPixels = sourceWidth * sourceHeight;
  if (totalPixels > safeMaxPixels) {
    scale = Math.min(scale, Math.sqrt(safeMaxPixels / totalPixels));
  }

  return {
    width: Math.max(1, Math.round(sourceWidth * scale)),
    height: Math.max(1, Math.round(sourceHeight * scale)),
  };
}

export function getPetModeAlwaysOnTopLevel() {
  return "floating";
}

export function getScreenshotCaptureOutputConfig({ purpose = "attachment" } = {}) {
  if (purpose === "selection") {
    return {
      filename: "screen-capture.jpg",
      jpegQuality: 92,
      maxPixels: 1920 * 1080,
      maxWidth: 1920,
      mimeType: "image/jpeg",
    };
  }
  if (purpose === "selection-attachment") {
    return {
      filename: "screen-capture.jpg",
      jpegQuality: 92,
      maxPixels: 1920 * 1080,
      maxWidth: 1920,
      mimeType: "image/jpeg",
    };
  }

  return {
    filename: "screen-capture.jpg",
    jpegQuality: 98,
    mimeType: "image/jpeg",
  };
}

export function getScreenshotCapturePlan({
  displaySize,
  purpose = "attachment",
  scaleFactor = 1,
} = {}) {
  const normalizedScaleFactor = Math.max(1, Math.ceil(normalizePositiveNumber(scaleFactor, 1)));
  const sourceSize = {
    width: Math.max(1, Math.floor(normalizePositiveNumber(displaySize?.width) * normalizedScaleFactor)),
    height: Math.max(1, Math.floor(normalizePositiveNumber(displaySize?.height) * normalizedScaleFactor)),
  };
  const outputConfig = getScreenshotCaptureOutputConfig({ purpose });

  return {
    captureSize: getCaptureResizeTarget({
      width: sourceSize.width,
      height: sourceSize.height,
      maxWidth: outputConfig.maxWidth,
      maxPixels: outputConfig.maxPixels,
    }),
    outputConfig,
    sourceSize,
  };
}

function getAspectRatio(size = {}) {
  const width = normalizePositiveNumber(size.width, 0);
  const height = normalizePositiveNumber(size.height, 0);
  if (!width || !height) {
    return 0;
  }
  return width / height;
}

function getArea(size = {}) {
  const width = normalizePositiveNumber(size.width, 0);
  const height = normalizePositiveNumber(size.height, 0);
  return width * height;
}

function getSourceThumbnailSize(source) {
  const size = source?.thumbnail?.getSize?.() || {};
  return {
    width: normalizePositiveNumber(size.width, 0),
    height: normalizePositiveNumber(size.height, 0),
  };
}

export function getCaptureSourceForDisplay({
  sources = [],
  targetDisplay,
  targetSize,
} = {}) {
  const targetDisplayId = String(targetDisplay?.id ?? "");
  const exactDisplayMatch = sources.find((source) => {
    const displayId = String(source?.display_id || "");
    return displayId && displayId === targetDisplayId;
  });

  if (exactDisplayMatch) {
    return exactDisplayMatch;
  }

  const fallbackTargetSize = {
    width: normalizePositiveNumber(targetSize?.width, targetDisplay?.size?.width ?? 0),
    height: normalizePositiveNumber(targetSize?.height, targetDisplay?.size?.height ?? 0),
  };
  const targetAspectRatio = getAspectRatio(fallbackTargetSize);
  const targetArea = Math.max(1, getArea(fallbackTargetSize));

  let bestSource = null;
  let bestScore = Number.POSITIVE_INFINITY;

  for (const source of sources) {
    const sourceSize = getSourceThumbnailSize(source);
    const sourceAspectRatio = getAspectRatio(sourceSize);
    const sourceArea = getArea(sourceSize);
    if (!sourceAspectRatio || !sourceArea) {
      continue;
    }

    const aspectPenalty = Math.abs(sourceAspectRatio - targetAspectRatio);
    const areaPenalty = Math.abs(sourceArea - targetArea) / targetArea;
    const widthPenalty = Math.abs(sourceSize.width - fallbackTargetSize.width)
      / Math.max(1, fallbackTargetSize.width);
    const heightPenalty = Math.abs(sourceSize.height - fallbackTargetSize.height)
      / Math.max(1, fallbackTargetSize.height);
    const score = (aspectPenalty * 10) + areaPenalty + widthPenalty + heightPenalty;

    if (score < bestScore) {
      bestScore = score;
      bestSource = source;
    }
  }

  return bestSource || sources[0] || null;
}

export function getDisplayForScreenshotSession({
  displays = [],
  cursorPoint,
} = {}) {
  const pointX = Number(cursorPoint?.x);
  const pointY = Number(cursorPoint?.y);

  const containingDisplay = displays.find((display) => {
    const bounds = display?.bounds || {};
    const left = Number(bounds.x || 0);
    const top = Number(bounds.y || 0);
    const right = left + Number(bounds.width || 0);
    const bottom = top + Number(bounds.height || 0);

    return (
      Number.isFinite(pointX)
      && Number.isFinite(pointY)
      && pointX >= left
      && pointX < right
      && pointY >= top
      && pointY < bottom
    );
  });

  if (containingDisplay) {
    return containingDisplay;
  }

  let bestDisplay = null;
  let bestDistance = Number.POSITIVE_INFINITY;
  for (const display of displays) {
    const bounds = display?.bounds || {};
    const left = Number(bounds.x || 0);
    const top = Number(bounds.y || 0);
    const right = left + Number(bounds.width || 0);
    const bottom = top + Number(bounds.height || 0);
    const nearestX = Math.min(Math.max(pointX, left), right);
    const nearestY = Math.min(Math.max(pointY, top), bottom);
    const distance = ((pointX - nearestX) ** 2) + ((pointY - nearestY) ** 2);
    if (distance < bestDistance) {
      bestDistance = distance;
      bestDisplay = display;
    }
  }

  return bestDisplay || displays[0] || null;
}

export function getScreenshotSelectionBounds(displayBounds = {}) {
  return {
    x: Number(displayBounds.x || 0),
    y: Number(displayBounds.y || 0),
    width: Math.max(1, Math.round(Number(displayBounds.width || 0))),
    height: Math.max(1, Math.round(Number(displayBounds.height || 0))),
  };
}

export function getScreenshotRestoreWindowConfig({
  mode = "window",
  forceIgnoreMouse = false,
  hoveringComponentCount = 0,
} = {}) {
  if (mode === "pet") {
    const ignoreMouseEvents = forceIgnoreMouse || Number(hoveringComponentCount || 0) === 0;
    return {
      alwaysOnTop: true,
      alwaysOnTopLevel: getPetModeAlwaysOnTopLevel(),
      focusable: !ignoreMouseEvents,
      ignoreMouseEvents,
      moveTopAfterShow: true,
      resizable: false,
      skipTaskbar: true,
    };
  }

  return {
    alwaysOnTop: false,
    alwaysOnTopLevel: undefined,
    focusable: true,
    ignoreMouseEvents: false,
    moveTopAfterShow: false,
    resizable: true,
    skipTaskbar: false,
  };
}
