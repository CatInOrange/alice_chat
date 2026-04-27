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

  const x = Number(model.x ?? model.position?.x ?? 0);
  const y = Number(model.y ?? model.position?.y ?? 0);
  const width = Number(model.width ?? 0);
  const height = Number(model.height ?? 0);

  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    const rect = getModelScreenRect();
    if (!rect) {
      return null;
    }
    return {
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom,
      width: rect.width,
      height: rect.height,
    };
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
}

export function isLeftButtonPressed(): boolean {
  return (lastPointer.buttons & 1) !== 0;
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

  if (lastPointer.pointerType === 'touch') {
    return;
  }

  try {
    applyLive2DFocus({
      config: next,
      pointer: lastPointer,
      canvasRect: canvas.getBoundingClientRect(),
      model,
      manager,
      view,
      devicePixelRatio: window.devicePixelRatio || 1,
    });
  } catch (error) {
    console.warn("Failed to apply focus center:", error);
  }
}
