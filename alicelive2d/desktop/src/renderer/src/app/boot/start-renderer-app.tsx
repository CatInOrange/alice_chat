import { createRoot } from "react-dom/client";
import RootApp from "@/app/root-app";
import { LAppAdapter } from "../../../WebSDK/src/lappadapter";
import { ensureBootOverlay, hideBootOverlay } from "@/boot-overlay-utils";
import i18n from "@/i18n";

function formatFatalError(error: unknown, fallback: string) {
  if (error instanceof Error) {
    return error.stack || error.message || fallback;
  }
  if (typeof error === "string" && error.trim()) {
    return error;
  }
  return fallback;
}

function installConsoleFilters() {
  const originalConsoleWarn = console.warn;
  console.warn = (...args) => {
    if (typeof args[0] === "string" && args[0].includes("onnxruntime")) {
      return;
    }
    originalConsoleWarn.apply(console, args);
  };

  const originalConsoleError = console.error;
  const errorMessagesToIgnore = ["Warning: Failed"];
  console.error = (...args: any[]) => {
    if (typeof args[0] === "string") {
      const shouldIgnore = errorMessagesToIgnore.some((message) => args[0].startsWith(message));
      if (shouldIgnore) {
        return;
      }
    }
    originalConsoleError.apply(console, args);
  };
}

function installFatalErrorOverlay() {
  window.addEventListener("error", (event) => {
    const detail = formatFatalError(
      event.error || event.message,
      i18n.t("boot.rendererErrorFallback"),
    );
    ensureBootOverlay(document, {
      status: "error",
      message: i18n.t("boot.rendererCrashed", { detail }),
    });
  });

  window.addEventListener("unhandledrejection", (event) => {
    const detail = formatFatalError(
      event.reason,
      i18n.t("boot.rendererPromiseFallback"),
    );
    ensureBootOverlay(document, {
      status: "error",
      message: i18n.t("boot.rendererCrashed", { detail }),
    });
  });
}

export function startRendererApp() {
  if (typeof window === "undefined") {
    return;
  }

  installConsoleFilters();
  installFatalErrorOverlay();

  (window as any).getLAppAdapter = () => LAppAdapter.getInstance();
  document.documentElement.style.height = "100%";
  document.body.style.height = "100%";
  document.body.style.margin = "0";
  document.body.style.background = "#020617";

  ensureBootOverlay(document, {
    status: "loading",
    message: i18n.t("boot.loading"),
  });

  createRoot(document.getElementById("root")!).render(<RootApp />);
  requestAnimationFrame(() => {
    hideBootOverlay(document);
  });
}
