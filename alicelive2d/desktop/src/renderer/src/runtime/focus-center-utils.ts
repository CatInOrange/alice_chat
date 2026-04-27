export function resolveFocusCenterConfig({
  manifest,
  focusCenterByModel,
  modelId,
}) {
  const resolvedModelId = String(modelId || manifest?.selectedModelId || manifest?.model?.id || "").trim();
  const manifestDefaults = {
    ...(manifest?.live2d?.focusCenter || {}),
    ...(manifest?.model?.live2d?.focusCenter || {}),
  };
  const storedConfig = resolvedModelId ? focusCenterByModel?.[resolvedModelId] : undefined;

  return {
    enabled: storedConfig?.enabled ?? manifestDefaults.enabled ?? true,
    headRatio: Number(storedConfig?.headRatio ?? manifestDefaults.headRatio ?? 0.25),
  };
}
