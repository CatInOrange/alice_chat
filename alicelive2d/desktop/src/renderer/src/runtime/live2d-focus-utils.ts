function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

export function applyLive2DFocus({
  config,
  pointer,
  canvasRect,
  model,
  manager,
  view,
  devicePixelRatio = 1,
}) {
  if (
    config?.enabled === false
    || !pointer
    || !canvasRect
    || !Number.isFinite(Number(canvasRect.width))
    || !Number.isFinite(Number(canvasRect.height))
    || Number(canvasRect.width) <= 0
    || Number(canvasRect.height) <= 0
  ) {
    return false;
  }

  const width = Number(canvasRect.width);
  const height = Number(canvasRect.height);
  // In pet mode, pointer.x is in screen/renderer coordinates (0 to renderer width),
  // while canvasRect.width is the canvas width. We need to scale pointer.x from
  // renderer coordinates to canvas coordinates.
  const rendererWidth = typeof window !== 'undefined' ? window.innerWidth : width;
  const localX = clamp(
    ((Number(pointer.x) - Number(canvasRect.left || 0)) * width) / rendererWidth,
    0,
    width
  );
  const localY = clamp(Number(pointer.y) - Number(canvasRect.top || 0), 0, height);
  const focusedY = localY;

  if (typeof model?.focus === "function") {
    model.focus(localX, focusedY, false);
    return true;
  }

  // Only apply drag (gaze tracking) when left mouse button is pressed (bit 0)
  const leftButtonPressed = pointer && (Number(pointer.buttons) & 1) !== 0;

  if (
    leftButtonPressed
    && typeof manager?.onDrag === "function"
    && typeof view?.transformViewX === "function"
    && typeof view?.transformViewY === "function"
  ) {
    const scaledX = localX;
    const scaledY = focusedY;
    const dragX = view.transformViewX(scaledX);
    const dragY = view.transformViewY(scaledY);

    // DEBUG: Send comprehensive info to backend
    const touchLike = typeof window !== 'undefined' && ('ontouchstart' in window || navigator.maxTouchPoints > 0);
    const pointerType = pointer?.pointerType ?? null;
    const debugData: Record<string, string | number | boolean | null> = {
      type: 'dragY',
      source: 'applyLive2DFocus',
      userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : null,
      isTouchDevice: touchLike,
      pointerType,
      buttons: Number(pointer?.buttons ?? 0),

      // Viewport and canvas info
      windowInnerWidth: typeof window !== 'undefined' ? Number(window.innerWidth) : null,
      windowInnerHeight: typeof window !== 'undefined' ? Number(window.innerHeight) : null,
      canvasLeft: Number(canvasRect.left || 0),
      canvasTop: Number(canvasRect.top || 0),
      canvasWidth: width,
      canvasHeight: height,

      // Raw pointer info
      pointerX_raw: Number(pointer.x),
      pointerY_raw: Number(pointer.y),

      // Calculated local position
      rendererWidth,
      localX,
      localY,
      focusedY,

      // Config/model info
      configHeadRatio: Number(config?.headRatio ?? 0.25),
      modelY: Number(model?.y),
      modelHeight: Number(model?.height),

      // Final drag values
      dragX,
      dragY,
      finalDragY: pointerType === 'touch' ? -dragY : dragY,

      // Scaling
      devicePixelRatio: Number(devicePixelRatio || 1),
      scaledX,
      scaledY,

      // Matrix values
      _deviceToScreen_tr0: view._deviceToScreen?._tr?.[0] ?? 0,
      _deviceToScreen_tr5: view._deviceToScreen?._tr?.[5] ?? 0,
      _deviceToScreen_tr12: view._deviceToScreen?._tr?.[12] ?? 0,
      _deviceToScreen_tr13: view._deviceToScreen?._tr?.[13] ?? 0,
      _viewMatrix_tr0: view._viewMatrix?._tr?.[0] ?? 0,
      _viewMatrix_tr5: view._viewMatrix?._tr?.[5] ?? 0,
      _viewMatrix_tr12: view._viewMatrix?._tr?.[12] ?? 0,
      _viewMatrix_tr13: view._viewMatrix?._tr?.[13] ?? 0,
    };
    // Add matrix values for debugging
    if (view._deviceToScreen) {
      debugData['_deviceToScreen_tr0'] = view._deviceToScreen._tr[0];  // X scale
      debugData['_deviceToScreen_tr5'] = view._deviceToScreen._tr[5];  // Y scale
      debugData['_deviceToScreen_tr12'] = view._deviceToScreen._tr[12]; // X translation
      debugData['_deviceToScreen_tr13'] = view._deviceToScreen._tr[13]; // Y translation
    }
    if (view._viewMatrix) {
      debugData['_viewMatrix_tr0'] = view._viewMatrix._tr[0];  // X scale
      debugData['_viewMatrix_tr5'] = view._viewMatrix._tr[5];  // Y scale
      debugData['_viewMatrix_tr12'] = view._viewMatrix._tr[12]; // X translation
      debugData['_viewMatrix_tr13'] = view._viewMatrix._tr[13]; // Y translation
    }
    // Try multiple backends - localhost:18080 (desktop) and :8080 (web version via nginx)
    if (Number.isFinite(Number(dragX)) && Number.isFinite(Number(dragY))) {
      const finalDragY = pointerType === 'touch' ? -dragY : dragY;
      manager.onDrag(dragX, finalDragY);
      return true;
    }
  }

  return false;
}
