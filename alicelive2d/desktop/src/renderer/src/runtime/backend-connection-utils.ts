import { normalizeBaseUrl } from "../platform/backend/openclaw-api.ts";

const DEFAULT_BACKEND_BASE_URL = "";  // 空字符串会触发 normalizeBaseUrl 使用 window.location.origin

function toPositiveInteger(value: unknown, fallback = 0): number {
  const numeric = Number(value);
  if (!Number.isInteger(numeric) || numeric < 0) {
    return fallback;
  }
  return numeric;
}

export function beginBackendConnectionSession(store?: { activeSessionId?: number }): number {
  const targetStore = store || { activeSessionId: 0 };
  const nextSessionId = toPositiveInteger(targetStore.activeSessionId) + 1;
  targetStore.activeSessionId = nextSessionId;
  return nextSessionId;
}

export function getActiveBackendConnectionSession(store?: { activeSessionId?: number }): number {
  return toPositiveInteger(store?.activeSessionId);
}

export function isBackendConnectionSessionCurrent(
  sessionId: unknown,
  store?: { activeSessionId?: number },
): boolean {
  const normalizedSessionId = toPositiveInteger(sessionId, -1);
  if (normalizedSessionId <= 0) {
    return false;
  }

  return normalizedSessionId === getActiveBackendConnectionSession(store);
}

export function shouldApplyBackendConnectionUpdate({
  sessionId,
  store,
  isDisposed = false,
}: {
  sessionId?: unknown;
  store?: { activeSessionId?: number };
  isDisposed?: boolean;
} = {}): boolean {
  return !isDisposed && isBackendConnectionSessionCurrent(sessionId, store);
}

export function shouldPreferConfiguredBackendUrl({
  currentUrl,
  configuredUrl,
  defaultUrl = DEFAULT_BACKEND_BASE_URL,
}: {
  currentUrl?: string;
  configuredUrl?: string;
  defaultUrl?: string;
} = {}): boolean {
  const normalizedConfiguredUrl = String(configuredUrl || "").trim();
  if (!normalizedConfiguredUrl) {
    return false;
  }

  const normalizedCurrentUrl = String(currentUrl || "").trim();
  if (!normalizedCurrentUrl) {
    return true;
  }

  return normalizeBaseUrl(normalizedCurrentUrl) === normalizeBaseUrl(defaultUrl);
}
