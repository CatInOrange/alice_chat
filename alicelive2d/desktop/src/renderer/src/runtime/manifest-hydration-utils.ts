function getTtsProviderIds(manifest) {
  return new Set((manifest?.model?.chat?.tts?.providers || []).map((provider) => String(provider?.id || "")));
}

function getProviderIds(manifest) {
  return new Set((manifest?.model?.chat?.providers || []).map((provider) => String(provider?.id || "")));
}

export function getManifestHydrationState({
  state,
  manifest,
}) {
  const modelId = String(manifest?.selectedModelId || manifest?.model?.id || "");
  const focusDefaults = {
    ...(manifest?.live2d?.focusCenter || {}),
    ...(manifest?.model?.live2d?.focusCenter || {}),
  };
  const providerIds = getProviderIds(manifest);
  const ttsProviderIds = getTtsProviderIds(manifest);
  const currentProviderId = String(state?.currentProviderId || "");
  const currentTtsProvider = String(state?.ttsProvider || "");
  const currentFocusCenter = modelId ? state?.focusCenterByModel?.[modelId] : undefined;

  return {
    manifest,
    quickActions: manifest?.model?.quickActions || [],
    motions: manifest?.model?.motions || [],
    expressions: manifest?.model?.expressions || [],
    persistentToggles: manifest?.model?.persistentToggles || {},
    currentProviderId: providerIds.has(currentProviderId)
      ? currentProviderId
      : String(manifest?.model?.chat?.defaultProviderId || currentProviderId),
    ttsEnabled: state?.ttsEnabled ?? (manifest?.model?.chat?.tts?.enabled ?? true),
    ttsProvider: ttsProviderIds.has(currentTtsProvider)
      ? currentTtsProvider
      : String(manifest?.model?.chat?.tts?.provider || currentTtsProvider),
    focusCenterByModel: modelId
      ? {
        ...(state?.focusCenterByModel || {}),
        [modelId]: currentFocusCenter || {
          enabled: focusDefaults.enabled ?? true,
          headRatio: Number(focusDefaults.headRatio ?? 0.25),
        },
      }
      : (state?.focusCenterByModel || {}),
  };
}
