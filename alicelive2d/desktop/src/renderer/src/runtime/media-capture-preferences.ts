export const IMAGE_COMPRESSION_QUALITY_KEY = "appImageCompressionQuality";
export const DEFAULT_IMAGE_COMPRESSION_QUALITY = 0.8;
export const IMAGE_MAX_WIDTH_KEY = "appImageMaxWidth";
export const DEFAULT_IMAGE_MAX_WIDTH = 0;

export function parseMediaCaptureNumber(value, fallback, {
  min = Number.NEGATIVE_INFINITY,
  max = Number.POSITIVE_INFINITY,
} = {}) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    return fallback;
  }
  return parsed;
}

export function readMediaCaptureNumber(storage, key, fallback, constraints) {
  const rawValue = storage?.getItem?.(key);
  return parseMediaCaptureNumber(rawValue, fallback, constraints);
}
