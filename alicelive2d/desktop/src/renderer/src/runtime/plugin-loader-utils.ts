function normalizeManifest(raw, fallbackId) {
  return {
    id: String(raw?.id || fallbackId),
    capabilities: Array.isArray(raw?.capabilities) ? raw.capabilities : [],
  };
}

export function rebuildPluginCatalogState(items, loadedPlugins) {
  if (loadedPlugins?.clear) {
    loadedPlugins.clear();
  }

  const pluginItems = new Map();
  const capabilityIndex = new Map();

  for (const item of items || []) {
    pluginItems.set(item.id, item);
    const manifest = normalizeManifest(item.manifest, item.id);
    for (const capability of manifest.capabilities || []) {
      if (!capability?.name) {
        continue;
      }
      capabilityIndex.set(String(capability.name), {
        pluginId: item.id,
        capability,
      });
    }
  }

  return { pluginItems, capabilityIndex };
}
