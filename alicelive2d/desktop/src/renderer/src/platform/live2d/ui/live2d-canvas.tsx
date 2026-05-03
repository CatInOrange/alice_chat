/* eslint-disable no-shadow */
/* eslint-disable no-underscore-dangle */
/* eslint-disable @typescript-eslint/ban-ts-comment */
import { memo, useEffect, useRef } from "react";
import { useLive2DConfig } from "@/context/live2d-config-context";
import { useLive2DModel } from "@/hooks/canvas/use-live2d-model";
import { useLive2DResize } from "@/hooks/canvas/use-live2d-resize";
import { useForceIgnoreMouse } from "@/hooks/utils/use-force-ignore-mouse";
import { useMode } from "@/context/mode-context";
import {
  resetTrackedPointerToCenter,
  setConstrainPointerToCanvasHover,
  setPointerInsideCanvas,
} from "@/runtime/live2d-bridge";

interface Live2DProps {
  showSidebar?: boolean;
}

export const Live2D = memo(
  ({ showSidebar }: Live2DProps): JSX.Element => {
    const { forceIgnoreMouse } = useForceIgnoreMouse();
    const { modelInfo } = useLive2DConfig();
    const { mode } = useMode();
    const internalContainerRef = useRef<HTMLDivElement>(null);
    const isPet = mode === 'pet';
    const lastDebugMoveRef = useRef(0);

    const debugLog = (payload: Record<string, unknown>) => {
      const entry = {
        scope: 'live2d-canvas',
        mode,
        isPet,
        ...payload,
      };
      window.api?.debugLog?.(entry);
      console.log('[live2d-canvas]', entry);
    };

    // Get canvasRef from useLive2DResize
    const { canvasRef } = useLive2DResize({
      containerRef: internalContainerRef,
      modelInfo,
      showSidebar,
    });

    // Pass canvasRef to useLive2DModel
    const { isDragging, handlers } = useLive2DModel({
      modelInfo,
      canvasRef,
    });

    // Expose setExpression for console testing
    // useEffect(() => {
    //   const testSetExpression = (expressionValue: string | number) => {
    //     const lappAdapter = (window as any).getLAppAdapter?.();
    //     if (lappAdapter) {
    //       setExpression(expressionValue, lappAdapter, `[Console Test] Set expression to: ${expressionValue}`);
    //     } else {
    //       console.error('[Console Test] LAppAdapter not found.');
    //     }
    //   };

    //   // Expose the function to the window object
    //   (window as any).testSetExpression = testSetExpression;
    //   console.log('[Debug] testSetExpression function exposed to window.');

    //   // Cleanup function to remove the function from window when the component unmounts
    //   return () => {
    //     delete (window as any).testSetExpression;
    //     console.log('[Debug] testSetExpression function removed from window.');
    //   };
    // }, [setExpression]);

    useEffect(() => {
      setConstrainPointerToCanvasHover(!isPet);
      debugLog({ event: 'setConstrainPointerToCanvasHover', enabled: !isPet });
      return () => {
        setConstrainPointerToCanvasHover(false);
      };
    }, [isPet]);

    const handlePointerEnter = (e: React.PointerEvent<HTMLDivElement>) => {
      if (e.pointerType === "mouse") {
        setPointerInsideCanvas(true, {
          x: e.clientX,
          y: e.clientY,
          buttons: e.buttons,
          pointerType: e.pointerType,
        });
        debugLog({ event: 'pointerenter', x: e.clientX, y: e.clientY, buttons: e.buttons });
      }
    };

    const handlePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
      if (e.pointerType === "mouse" && e.button !== 0) {
        return;
      }
      if (isPet) {
        e.currentTarget.setPointerCapture?.(e.pointerId);
      }
      debugLog({ event: 'pointerdown', x: e.clientX, y: e.clientY, buttons: e.buttons, captured: isPet });
      handlers.onPointerDown(e);
    };

    const handlePointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
      if (e.pointerType === "mouse") {
        setPointerInsideCanvas(true, {
          x: e.clientX,
          y: e.clientY,
          buttons: e.buttons,
          pointerType: e.pointerType,
        });
        const now = Date.now();
        if (now - lastDebugMoveRef.current >= 250) {
          lastDebugMoveRef.current = now;
          debugLog({ event: 'pointermove', x: e.clientX, y: e.clientY, buttons: e.buttons });
        }
      }
      handlers.onPointerMove(e);
    };

    const handlePointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
      debugLog({ event: 'pointerup', x: e.clientX, y: e.clientY, buttons: e.buttons, captured: isPet });
      handlers.onPointerUp(e);
      if (isPet) {
        e.currentTarget.releasePointerCapture?.(e.pointerId);
      }
    };

    const handlePointerCancel = (e: React.PointerEvent<HTMLDivElement>) => {
      handlers.onPointerCancel(e);
      if (isPet) {
        e.currentTarget.releasePointerCapture?.(e.pointerId);
      }
    };

    const handlePointerLeave = (e: React.PointerEvent<HTMLDivElement>) => {
      handlers.onPointerCancel(e);
      if (isPet) {
        e.currentTarget.releasePointerCapture?.(e.pointerId);
      }
      if (e.pointerType === "mouse") {
        debugLog({ event: 'pointerleave', x: e.clientX, y: e.clientY, buttons: e.buttons });
        setPointerInsideCanvas(false, {
          x: e.clientX,
          y: e.clientY,
          buttons: e.buttons,
          pointerType: e.pointerType,
        });
      }
    };

    const handleContextMenu = (e: React.MouseEvent) => {
      if (!isPet) {
        return;
      }

      e.preventDefault();
      console.log(
        "[ContextMenu] Pet mode right click detected, opening menu...",
      );
      window.api?.showContextMenu?.();
    };

    return (
      <div
        ref={internalContainerRef} // Ref for useLive2DResize if it observes this element
        id="live2d"
        style={{
          width: "100%",
          height: "100%",
          pointerEvents: isPet && forceIgnoreMouse ? "none" : "auto",
          overflow: "hidden",
          position: "relative",
          cursor: isDragging ? "grabbing" : "default",
          touchAction: "none",
          userSelect: "none",
          WebkitUserSelect: "none",
        }}
        onPointerEnter={handlePointerEnter}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerCancel}
        onPointerLeave={handlePointerLeave}
        onContextMenu={handleContextMenu}
      >
        <canvas
          id="canvas"
          ref={canvasRef}
          style={{
            width: "100%",
            height: "100%",
            pointerEvents: isPet && forceIgnoreMouse ? "none" : "auto",
            display: "block",
            cursor: isDragging ? "grabbing" : "default",
            touchAction: "none",
            userSelect: "none",
            WebkitUserSelect: "none",
          }}
        />
      </div>
    );
  },
);

Live2D.displayName = "Live2D";
