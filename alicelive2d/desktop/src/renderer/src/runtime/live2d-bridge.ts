import { CubismFramework } from "@framework/live2dcubismframework";
import * as LAppDefine from "../../WebSDK/src/lappdefine";
import { LAppDelegate } from "../../WebSDK/src/lappdelegate";
import type {
  FocusCenterConfig,
  PersistentToggleConfig,
  RuntimeRect,
} from "@/domains/types";
import { applyLive2DFocus } from "@/runtime/live2d-focus-utils.ts";

function getAdapter(): any {
  return (window as any).getLAppAdapter?.();
}

let lastDebugLogAt = 0;

function debugLog(payload: Record<string, unknown>): void {
  const now = Date.now();
  if ((payload.event === 'applyFocusCenter' || payload.event === 'setTrackedPointerPosition') && now - lastDebugLogAt < 250) {
    return;
  }
  lastDebugLogAt = now;
  const entry = {
    scope: 'live2d-bridge',
    ...payload,
  };
  (window as any).api?.debugLog?.(entry);
  if (typeof console !== 'undefined') {
    console.log('[live2d-bridge]', entry);
  }
}

function getModel(): any {
  return getAdapter()?.getModel?.();
}

export function playExpression(name: string): boolean {
  if (!name) {
    return false;
  }

  const adapter = getAdapter();
  if (!adapter?.setExpression) {
    return false;
  }

  try {
    adapter.setExpression(name);
    return true;
  } catch (error) {
    console.warn("Failed to set expression:", error);
    return false;
  }
}

export function playMotion(group = "", index = 0): boolean {
  const adapter = getAdapter();
  const model = adapter?.getModel?.();
  if (!model) {
    return false;
  }

  try {
    const priority = (LAppDefine as any)?.PriorityNormal ?? 3;
    if (adapter?.startMotion) {
      adapter.startMotion(group, index, priority);
    } else {
      model.startMotion(group, index, priority);
    }
    return true;
  } catch (error) {
    console.warn("Failed to start motion:", error);
    return false;
  }
}

export function applyStageDirectives(directives: unknown[]): void {
  for (const item of directives || []) {
    if (!item || typeof item !== "object") {
      continue;
    }

    const directive = item as Record<string, unknown>;
    const rawType = String(directive.type || directive.kind || directive.action || "").trim().toLowerCase();
    if ((rawType === "expression" || rawType === "expr" || rawType === "exp") && directive.name) {
      playExpression(String(directive.name));
      continue;
    }

    if (rawType === "motion" || rawType === "act" || "group" in directive || "motion" in directive) {
      playMotion(
        String(directive.group || directive.motion || ""),
        Number(directive.index || directive.motionIndex || 0) || 0,
      );
    }
  }
}

export function applyPersistentToggleState(
  persistentState: Record<string, boolean>,
  configMap: Record<string, PersistentToggleConfig>,
): void {
  const model = getModel();
  const coreModel = model?._model;
  if (!coreModel) {
    return;
  }

  const idManager = CubismFramework.getIdManager();
  if (!idManager) {
    return;
  }

  Object.entries(configMap || {}).forEach(([toggleId, config]) => {
    const paramId = String(config?.paramId || "").trim();
    if (!paramId) {
      return;
    }

    try {
      const handle = idManager.getId(paramId);
      const nextValue = persistentState[toggleId]
        ? Number(config?.onValue ?? 1)
        : Number(config?.offValue ?? 0);
      const weight = persistentState[toggleId]
        ? Number(config?.triggerWeight ?? 1)
        : Number(config?.resetWeight ?? 1);

      if (typeof coreModel.setParameterValueById === "function") {
        coreModel.setParameterValueById(handle, nextValue, weight);
        return;
      }

      if (typeof coreModel.addParameterValueById === "function") {
        const currentValue = typeof coreModel.getParameterValueById === "function"
          ? Number(coreModel.getParameterValueById(handle) || 0)
          : 0;
        coreModel.addParameterValueById(handle, nextValue - currentValue, weight);
      }
    } catch (error) {
      console.warn(`Failed to apply persistent toggle "${toggleId}":`, error);
    }
  });
}

export function getModelScreenRect(): DOMRect | null {
  const canvas = document.getElementById("canvas");
  if (!canvas) {
    return null;
  }
  return canvas.getBoundingClientRect();
}

export function getModelBounds(): RuntimeRect | null {
  const model = getModel();
  if (!model) {
    return null;
  }

  const x = Number(model.x ?? model.position?.x ?? NaN);
  const y = Number(model.y ?? model.position?.y ?? NaN);
  const width = Number(model.width ?? NaN);
  const height = Number(model.height ?? NaN);

  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    return null;
  }

  return {
    left: x - width / 2,
    top: y - height / 2,
    right: x + width / 2,
    bottom: y + height / 2,
    width,
    height,
  };
}

function isPointerInsideModelHitArea(
  pointer: { x: number; y: number },
  canvasRect: DOMRect,
  view: any,
  model: any,
): boolean | null {
  if (!pointer || !canvasRect || !view || !model) {
    return null;
  }

  const localX = Number(pointer.x) - Number(canvasRect.left || 0);
  const localY = Number(pointer.y) - Number(canvasRect.top || 0);

  if (!Number.isFinite(localX) || !Number.isFinite(localY)) {
    return null;
  }

  const modelX = view?._deviceToScreen?.transformX?.(localX);
  const modelY = view?._deviceToScreen?.transformY?.(localY);

  if (!Number.isFinite(Number(modelX)) || !Number.isFinite(Number(modelY))) {
    return null;
  }

  try {
    if (typeof model.anyhitTest === 'function' && model.anyhitTest(modelX, modelY) !== null) {
      return true;
    }
    if (typeof model.isHitOnModel === 'function') {
      return !!model.isHitOnModel(modelX, modelY);
    }
  } catch (error) {
    console.warn('Failed to test Live2D model hit area:', error);
  }

  return false;
}

export function setModelPositionFromScreen(x: number, y: number): boolean {
  const adapter = getAdapter();
  const model = adapter?.getModel();
  const view = LAppDelegate.getInstance().getView();
  if (!model || !model._modelMatrix || !view) return false;

  const canvas = document.getElementById("canvas") as HTMLCanvasElement;
  if (!canvas) return false;

  const rect = canvas.getBoundingClientRect();
  const scale = canvas.width / canvas.clientWidth;
  const scaledX = (x - rect.left) * scale;
  const scaledY = (y - rect.top) * scale;
  
  const modelX = view._deviceToScreen.transformX(scaledX);
  const modelY = view._deviceToScreen.transformY(scaledY);

  if (adapter.setModelPosition) {
    adapter.setModelPosition(modelX, modelY);
  } else {
    const matrix = model._modelMatrix.getArray();
    const newMatrix = [...matrix];
    newMatrix[12] = modelX;
    newMatrix[13] = modelY;
    model._modelMatrix.setMatrix(newMatrix);
  }
  
  model.x = x;
  model.y = y;
  
  return true;
}

let lastPointer: {
  x: number;
  y: number;
  buttons: number;
  pointerType?: string | null;
} = {
  x: typeof window !== "undefined" ? window.innerWidth * 0.5 : 0,
  y: typeof window !== "undefined" ? window.innerHeight * 0.5 : 0,
  buttons: 0,
  pointerType: null,
};

let constrainPointerToCanvasHover = false;
let isPointerInsideCanvas = false;
let forceCenterUntilPointerReenters = false;

export function setTrackedPointerPosition(pointer: { x: number; y: number; buttons?: number; pointerType?: string | null } | null | undefined): void {
  if (
    !pointer
    || !Number.isFinite(Number(pointer.x))
    || !Number.isFinite(Number(pointer.y))
  ) {
    return;
  }

  lastPointer = {
    x: Number(pointer.x),
    y: Number(pointer.y),
    buttons: pointer.buttons ?? lastPointer.buttons,
    pointerType: pointer.pointerType ?? lastPointer.pointerType ?? null,
  };
  debugLog({
    event: 'setTrackedPointerPosition',
    x: lastPointer.x,
    y: lastPointer.y,
    buttons: lastPointer.buttons,
    pointerType: lastPointer.pointerType,
  });
}

function focusModelCenter(): void {
  const canvas = document.getElementById("canvas") as HTMLCanvasElement | null;
  const rect = canvas?.getBoundingClientRect();
  const model = getModel();
  const manager = getAdapter()?.getMgr?.();

  if (rect && model && typeof model.focus === "function") {
    model.focus(rect.width * 0.5, rect.height * 0.5, false);
  }

  if (manager && typeof manager.onDrag === 'function') {
    manager.onDrag(0, 0);
  }
}

export function resetTrackedPointerToCenter(reason?: string): void {
  const canvas = document.getElementById("canvas") as HTMLCanvasElement | null;
  const rect = canvas?.getBoundingClientRect();

  forceCenterUntilPointerReenters = true;

  if (rect && Number.isFinite(rect.left) && Number.isFinite(rect.top)) {
    lastPointer = {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      buttons: 0,
      pointerType: 'mouse',
    };
  } else {
    lastPointer = {
      x: typeof window !== "undefined" ? window.innerWidth * 0.5 : 0,
      y: typeof window !== "undefined" ? window.innerHeight * 0.5 : 0,
      buttons: 0,
      pointerType: 'mouse',
    };
  }

  debugLog({
    event: 'resetTrackedPointerToCenter',
    reason: reason ?? null,
    x: lastPointer.x,
    y: lastPointer.y,
    forceCenterUntilPointerReenters,
  });
  focusModelCenter();
}

export function setConstrainPointerToCanvasHover(value: boolean): void {
  constrainPointerToCanvasHover = value;
  if (!value) {
    isPointerInsideCanvas = false;
    forceCenterUntilPointerReenters = false;
  }
  debugLog({ event: 'setConstrainPointerToCanvasHover', value, isPointerInsideCanvas, forceCenterUntilPointerReenters });
}

export function setPointerInsideCanvas(
  inside: boolean,
  pointer?: { x: number; y: number; buttons?: number; pointerType?: string | null } | null,
): void {
  isPointerInsideCanvas = inside;
  if (pointer) {
    setTrackedPointerPosition(pointer);
  }
  if (inside) {
    forceCenterUntilPointerReenters = false;
  }
  debugLog({
    event: 'setPointerInsideCanvas',
    insideCanvas: inside,
    x: pointer?.x ?? null,
    y: pointer?.y ?? null,
    buttons: pointer?.buttons ?? null,
    pointerType: pointer?.pointerType ?? null,
    forceCenterUntilPointerReenters,
  });
  if (!inside) {
    resetTrackedPointerToCenter('pointer-left-canvas');
  }
}

if (typeof window !== "undefined" && !(window as any).__OPENCLAW_POINTER_TRACKING__) {
  (window as any).__OPENCLAW_POINTER_TRACKING__ = true;
  window.addEventListener("pointerdown", (event) => {
    setTrackedPointerPosition({
      x: event.clientX,
      y: event.clientY,
      buttons: event.buttons,
      pointerType: event.pointerType,
    });

    if (event.pointerType === 'touch') {
      const view = LAppDelegate.getInstance().getView();
      if (view?.onTouchesBegan) {
        const canvas = document.getElementById("canvas") as HTMLCanvasElement | null;
        const rect = canvas?.getBoundingClientRect();
        if (rect) {
          view.onTouchesBegan(event.clientX - rect.left, event.clientY - rect.top);
        }
      }
    }
  });
  window.addEventListener("pointermove", (event) => {
    setTrackedPointerPosition({
      x: event.clientX,
      y: event.clientY,
      buttons: event.buttons,
      pointerType: event.pointerType,
    });

    if (event.pointerType === 'touch') {
      const view = LAppDelegate.getInstance().getView();
      if (view?.onTouchesMoved) {
        const canvas = document.getElementById("canvas") as HTMLCanvasElement | null;
        const rect = canvas?.getBoundingClientRect();
        if (rect) {
          view.onTouchesMoved(event.clientX - rect.left, event.clientY - rect.top);
        }
      }
    }
  });
  // Also track pointerup to handle mouse release outside window
  window.addEventListener("pointerup", (event) => {
    setTrackedPointerPosition({
      x: event.clientX,
      y: event.clientY,
      buttons: event.buttons,
      pointerType: event.pointerType,
    });

    if (event.pointerType === 'touch') {
      const view = LAppDelegate.getInstance().getView();
      if (view?.onTouchesEnded) {
        const canvas = document.getElementById("canvas") as HTMLCanvasElement | null;
        const rect = canvas?.getBoundingClientRect();
        if (rect) {
          view.onTouchesEnded(event.clientX - rect.left, event.clientY - rect.top);
        }
      }
      return;
    }

    // Fix: Reset drag to 0 when pointer is released
    const manager = getAdapter()?.getMgr?.();
    if (manager && typeof manager.onDrag === 'function') {
      manager.onDrag(0, 0);
    }
  });

  const forceCenterFromWindowExit = (reason: string) => {
    isPointerInsideCanvas = false;
    debugLog({ event: 'window-exit', reason, forceCenterUntilPointerReenters });
    resetTrackedPointerToCenter(reason);
  };

  window.addEventListener("mouseout", (event) => {
    const related = event.relatedTarget as Node | null;
    if (!related) {
      forceCenterFromWindowExit('window-mouseout-relatedTarget-null');
    }
  });

  window.addEventListener("blur", () => {
    forceCenterFromWindowExit('window-blur');
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== 'visible') {
      forceCenterFromWindowExit(`visibility-${document.visibilityState}`);
    }
  });
}

export function isLeftButtonPressed(): boolean {
  return (lastPointer.buttons & 1) !== 0;
}

function isPointerInsideRect(
  rect: { left: number; right: number; top: number; bottom: number },
  pointer: { x: number; y: number },
): boolean {
  return pointer.x >= rect.left
    && pointer.x <= rect.right
    && pointer.y >= rect.top
    && pointer.y <= rect.bottom;
}

function expandRect(
  rect: { left: number; right: number; top: number; bottom: number; width?: number; height?: number },
  paddingX: number,
  paddingY: number,
): { left: number; right: number; top: number; bottom: number } {
  return {
    left: rect.left - paddingX,
    right: rect.right + paddingX,
    top: rect.top - paddingY,
    bottom: rect.bottom + paddingY,
  };
}


export function applyFocusCenter(config: FocusCenterConfig | null | undefined): void {
  const next = config || {};
  if (next.enabled === false) {
    return;
  }

  const canvas = document.getElementById("canvas") as HTMLCanvasElement | null;
  const model = getModel();
  const manager = getAdapter()?.getMgr?.();
  const view = LAppDelegate.getInstance().getView();
  if (!canvas || !model || (!manager && !view)) {
    return;
  }

  if (lastPointer.pointerType === 'touch' || isLeftButtonPressed()) {
    debugLog({
      event: 'applyFocusCenter-skip',
      reason: lastPointer.pointerType === 'touch' ? 'touch' : 'left-button-pressed',
      insideCanvas: isPointerInsideCanvas,
      pointerType: lastPointer.pointerType,
      buttons: lastPointer.buttons,
    });
    return;
  }

  const canvasRect = canvas.getBoundingClientRect();
  const live2dRect = (document.getElementById("live2d") as HTMLElement | null)?.getBoundingClientRect() ?? canvasRect;
  const modelBounds = getModelBounds();
  const expandedModelRect = modelBounds
    ? expandRect(
      modelBounds,
      Math.max(24, Number(modelBounds.width || 0) * 0.18),
      Math.max(24, Number(modelBounds.height || 0) * 0.14),
    )
    : null;
  if (lastPointer.pointerType === 'mouse') {
    const insideModelHitArea = isPointerInsideModelHitArea(lastPointer, canvasRect, view, model);
    const insideModelBounds = modelBounds ? isPointerInsideRect(modelBounds, lastPointer) : insideModelHitArea;
    const insideCanvasRect = isPointerInsideRect(canvasRect, lastPointer);
    const insideLive2DRect = isPointerInsideRect(live2dRect, lastPointer);
    const insideActiveRect = constrainPointerToCanvasHover
      ? (expandedModelRect ? isPointerInsideRect(expandedModelRect, lastPointer) : insideModelHitArea)
      : insideLive2DRect;

    if (constrainPointerToCanvasHover && forceCenterUntilPointerReenters) {
      debugLog({
        event: 'applyFocusCenter-center',
        reason: 'force-center-until-pointer-reenters',
        insideCanvas: isPointerInsideCanvas,
        x: lastPointer.x,
        y: lastPointer.y,
        insideModelBounds,
        insideModelHitArea,
        insideCanvasRect,
        insideLive2DRect,
        insideActiveRect,
      });
      focusModelCenter();
      return;
    }

    const isOutsideActiveRegion = !insideActiveRect;

    if (constrainPointerToCanvasHover && isOutsideActiveRegion) {
      forceCenterUntilPointerReenters = true;
      debugLog({
        event: 'applyFocusCenter-center',
        reason: 'outside-active-rect',
        insideCanvas: isPointerInsideCanvas,
        x: lastPointer.x,
        y: lastPointer.y,
        insideModelBounds,
        insideModelHitArea,
        insideCanvasRect,
        insideLive2DRect,
        insideActiveRect,
        live2dRect,
        activeRect: expandedModelRect,
      });
      focusModelCenter();
      return;
    }
  }

  const debugInsideModelHitArea = lastPointer.pointerType === 'mouse'
    ? isPointerInsideModelHitArea(lastPointer, canvasRect, view, model)
    : null;
  const debugInsideModelBounds = lastPointer.pointerType === 'mouse'
    ? (modelBounds ? isPointerInsideRect(modelBounds, lastPointer) : debugInsideModelHitArea)
    : null;
  const debugInsideCanvasRect = lastPointer.pointerType === 'mouse' ? isPointerInsideRect(canvasRect, lastPointer) : null;
  const debugInsideLive2DRect = lastPointer.pointerType === 'mouse' ? isPointerInsideRect(live2dRect, lastPointer) : null;
  const debugInsideActiveRect = lastPointer.pointerType === 'mouse'
    ? (constrainPointerToCanvasHover
      ? (expandedModelRect ? isPointerInsideRect(expandedModelRect, lastPointer) : debugInsideModelHitArea)
      : debugInsideLive2DRect)
    : null;

  debugLog({
    event: 'applyFocusCenter',
    x: lastPointer.x,
    y: lastPointer.y,
    insideCanvas: isPointerInsideCanvas,
    insideModelBounds: debugInsideModelBounds,
    insideModelHitArea: debugInsideModelHitArea,
    insideCanvasRect: debugInsideCanvasRect,
    insideLive2DRect: debugInsideLive2DRect,
    insideActiveRect: debugInsideActiveRect,
    pointerType: lastPointer.pointerType,
    buttons: lastPointer.buttons,
  });

  try {
    applyLive2DFocus({
      config: next,
      pointer: lastPointer,
      canvasRect,
      model,
      manager,
      view,
      devicePixelRatio: window.devicePixelRatio || 1,
    });
  } catch (error) {
    console.warn("Failed to apply focus center:", error);
  }
}
