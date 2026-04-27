import { normalizeBaseUrl } from "../platform/backend/openclaw-api.ts";

const SUPPORTED_LANGUAGES = new Set(["en", "zh"]);
const DEFAULT_BACKEND_BASE_URL = "";  // 空字符串会触发 normalizeBaseUrl 使用 window.location.origin

function splitFieldKey(key) {
  return String(key || "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
}

function toTitleCase(value) {
  return value.charAt(0).toUpperCase() + value.slice(1).toLowerCase();
}

export function normalizeSupportedLanguage(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .split(/[-_]/)[0];

  if (SUPPORTED_LANGUAGES.has(normalized)) {
    return normalized;
  }

  return "en";
}

export function resolveProviderFieldLabel(field) {
  const explicitLabel = String(field?.label || "").trim();
  if (explicitLabel) {
    return explicitLabel;
  }

  const words = splitFieldKey(field?.key);
  if (!words.length) {
    return "Field";
  }

  return words.map(toTitleCase).join(" ");
}

export function resolveProviderFieldPlaceholder(field) {
  const explicitPlaceholder = String(field?.placeholder || "").trim();
  if (explicitPlaceholder) {
    return explicitPlaceholder;
  }

  return resolveProviderFieldLabel(field);
}

export function resolveBackendUrlCommit({
  draftUrl,
  currentUrl,
  defaultUrl = DEFAULT_BACKEND_BASE_URL,
}: {
  draftUrl?: string;
  currentUrl?: string;
  defaultUrl?: string;
} = {}) {
  const normalizedDraft = String(draftUrl || "").trim();
  const nextUrl = normalizedDraft
    ? normalizeBaseUrl(normalizedDraft)
    : defaultUrl;

  return {
    nextUrl,
    shouldStore: nextUrl !== String(currentUrl || ""),
  };
}
