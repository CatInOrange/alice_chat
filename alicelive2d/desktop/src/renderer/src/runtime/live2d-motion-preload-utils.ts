function normalizeCount(value) {
  const count = Number(value);
  if (!Number.isFinite(count) || count < 0) {
    return 0;
  }
  return Math.floor(count);
}

export function applySuccessfulMotionPreload({
  loadedCount,
  totalCount,
}) {
  const normalizedLoadedCount = normalizeCount(loadedCount) + 1;
  const normalizedTotalCount = normalizeCount(totalCount);

  return {
    loadedCount: normalizedLoadedCount,
    totalCount: normalizedTotalCount,
    shouldFinalizeSetup:
      normalizedTotalCount === 0 || normalizedLoadedCount >= normalizedTotalCount,
  };
}

export function applyFailedMotionPreload({
  loadedCount,
  totalCount,
}) {
  const normalizedLoadedCount = normalizeCount(loadedCount);
  const normalizedTotalCount = Math.max(0, normalizeCount(totalCount) - 1);

  return {
    loadedCount: normalizedLoadedCount,
    totalCount: normalizedTotalCount,
    shouldFinalizeSetup:
      normalizedTotalCount === 0 || normalizedLoadedCount >= normalizedTotalCount,
  };
}
