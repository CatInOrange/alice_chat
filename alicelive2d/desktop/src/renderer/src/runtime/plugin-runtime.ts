import type { ComposerAttachment } from "@/domains/types";
import { dataUrlToComposerAttachment } from "@/domains/composer/store";
import { playExpression, playMotion } from "./live2d-bridge";
import { rebuildPluginCatalogState } from "./plugin-loader-utils.ts";

export type PluginPermission =
  | "desktop.captureScreen"
  | "chat.sendToAI"
  | "ui.sendToUser"
  | "live2d.expression"
  | "live2d.motion"
  | "storage.read"
  | "storage.write"
  | "media.openFile";

export interface PluginCapability {
  name: string;
  description?: string;
  entry?: string;
  inputSchema?: Record<string, unknown>;
  outputSchema?: Record<string, unknown>;
  permissions?: PluginPermission[];
}

export interface PluginManifest {
  id: string;
  name: string;
  version: string;
  description?: string;
  entry?: string;
  capabilities?: PluginCapability[];
  permissions?: PluginPermission[];
}

interface PluginCatalogItem {
  id: string;
  source: "builtin" | "local";
  rootPath: string;
  entryUrl: string;
  manifest: Record<string, unknown>;
}

interface PluginExecutionResult {
  ok?: boolean;
  error?: string;
  result?: unknown;
  attachments?: ComposerAttachment[];
  logs?: string[];
}

interface PluginRuntimeDeps {
  listPlugins: () => Promise<{
    items: PluginCatalogItem[];
  }>;
  sendToAI: (payload: {
    text: string;
    attachments?: Array<{ type: "base64" | "url"; data: string; mediaType?: string }>;
  }) => Promise<void>;
  sendToUser: (
    text: string,
    attachments?: Array<{
      preview?: string;
      data?: string;
      mediaType?: string;
      filename?: string;
      type?: "base64" | "url";
    }>,
  ) => void;
  capturePrimaryScreen: () => Promise<string | null>;
  onLog?: (message: string) => void;
}

interface NormalizedAction {
  id: string;
  type: "expression" | "motion" | "play_music" | "stop_music" | "plugin.call";
  name?: string;
  group?: string;
  index?: number;
  capability?: string;
  args?: Record<string, unknown>;
  url?: string;
  trackId?: string;
}

interface LoadedPlugin {
  id: string;
  item: PluginCatalogItem;
  manifest: PluginManifest;
  module: Record<string, any>;
}

function cloneArgs<T>(value: T): T {
  return value ? JSON.parse(JSON.stringify(value)) : value;
}

function normalizeManifest(raw: Record<string, unknown>, fallbackId: string): PluginManifest {
  return {
    id: String(raw.id || fallbackId),
    name: String(raw.name || raw.id || fallbackId),
    version: String(raw.version || "0.0.0"),
    description: raw.description ? String(raw.description) : "",
    entry: raw.entry ? String(raw.entry) : undefined,
    capabilities: Array.isArray(raw.capabilities) ? raw.capabilities as PluginCapability[] : [],
    permissions: Array.isArray(raw.permissions) ? raw.permissions as PluginPermission[] : [],
  };
}

function dataUrlToAttachmentInput(dataUrl: string) {
  const attachment = dataUrlToComposerAttachment(dataUrl);
  return {
    type: "base64" as const,
    data: attachment.data,
    mediaType: attachment.mimeType,
  };
}

function normalizeAction(action: Record<string, unknown>, index: number): NormalizedAction | null {
  const rawType = String(action.type || "").trim();
  if (rawType === "expression") {
    return {
      id: String(action.id || `action_${index}`),
      type: "expression",
      name: String(action.name || ""),
    };
  }

  if (rawType === "motion") {
    return {
      id: String(action.id || `action_${index}`),
      type: "motion",
      group: String(action.group || ""),
      index: Number(action.index || 0) || 0,
    };
  }

  if (rawType === "play_music" || rawType === "stop_music") {
    return {
      id: String(action.id || `action_${index}`),
      type: rawType,
      url: action.url ? String(action.url) : undefined,
      trackId: action.trackId ? String(action.trackId) : undefined,
    };
  }

  if (rawType === "call" || action.tool || action.name) {
    return {
      id: String(action.id || `action_${index}`),
      type: "plugin.call",
      capability: String(action.tool || action.name || ""),
      args: (action.args || action.params || {}) as Record<string, unknown>,
    };
  }

  if (rawType === "plugin.call") {
    return {
      id: String(action.id || `action_${index}`),
      type: "plugin.call",
      capability: String(action.capability || ""),
      args: (action.args || {}) as Record<string, unknown>,
    };
  }

  return null;
}

export function createPluginRuntime(deps: PluginRuntimeDeps) {
  const pluginItems = new Map<string, PluginCatalogItem>();
  const loadedPlugins = new Map<string, LoadedPlugin>();
  const capabilityIndex = new Map<string, { pluginId: string; capability: PluginCapability }>();

  const log = (message: string) => {
    deps.onLog?.(message);
  };

  async function importPlugin(item: PluginCatalogItem): Promise<LoadedPlugin> {
    const existing = loadedPlugins.get(item.id);
    if (existing) {
      return existing;
    }

    const manifest = normalizeManifest(item.manifest, item.id);
    const module = await import(/* @vite-ignore */ item.entryUrl);
    const loaded: LoadedPlugin = {
      id: item.id,
      item,
      manifest,
      module: module as Record<string, any>,
    };
    loadedPlugins.set(item.id, loaded);
    return loaded;
  }

  function buildScopedApi(
    plugin: LoadedPlugin,
    capability: PluginCapability,
  ): Record<string, unknown> {
    const permissionSet = new Set<PluginPermission>([
      ...(plugin.manifest.permissions || []),
      ...(capability.permissions || []),
    ]);

    return {
      chat: permissionSet.has("chat.sendToAI")
        ? {
          sendToAI: async (payload: { text?: string; attachments?: Array<{ preview?: string; data?: string; mediaType?: string }> }) => {
            const attachments = (payload.attachments || [])
              .map((item) => item.preview || (item.data && item.mediaType ? `data:${item.mediaType};base64,${item.data}` : ""))
              .filter(Boolean)
              .map(dataUrlToAttachmentInput);

            await deps.sendToAI({
              text: String(payload.text || ""),
              attachments,
            });
          },
          ...(permissionSet.has("ui.sendToUser")
            ? {
              sendToUser: (
                text: string,
                attachments?: Array<{
                  preview?: string;
                  data?: string;
                  mediaType?: string;
                  filename?: string;
                  type?: "base64" | "url";
                }>,
              ) => {
                deps.sendToUser(text, attachments || []);
              },
            }
            : {}),
        }
        : {},
      desktop: permissionSet.has("desktop.captureScreen")
        ? {
          capturePrimaryScreen: async () => deps.capturePrimaryScreen(),
        }
        : {},
      ui: permissionSet.has("ui.sendToUser")
        ? {
          sendMessage: (text: string, attachments?: ComposerAttachment[]) => {
            deps.sendToUser(String(text || ""), attachments || []);
          },
          toast: (text: string) => {
            deps.sendToUser(String(text || ""), []);
          },
          log,
        }
        : { log },
      live2d: {
        ...(permissionSet.has("live2d.motion")
          ? {
            playMotion: (group = "", index = 0) => playMotion(group, index),
            triggerMotion: (group = "", index = 0) => playMotion(group, index),
          }
          : {}),
        ...(permissionSet.has("live2d.expression")
          ? {
            setExpression: (name: string) => playExpression(name),
            triggerExpression: (name: string) => playExpression(name),
          }
          : {}),
      },
      storage: {
        ...(permissionSet.has("storage.read")
          ? {
            get: (key: string) => {
              try {
                return localStorage.getItem(`plugin:${plugin.id}:${String(key || "")}`);
              } catch {
                return null;
              }
            },
          }
          : {}),
        ...(permissionSet.has("storage.write")
          ? {
            set: (key: string, value: string) => {
              localStorage.setItem(`plugin:${plugin.id}:${String(key || "")}`, String(value || ""));
            },
          }
          : {}),
      },
      utils: {
        dataUrlToAttachment: dataUrlToAttachmentInput,
      },
    };
  }

  async function refreshCatalog(): Promise<PluginCatalogItem[]> {
    const payload = await deps.listPlugins();
    const nextState = rebuildPluginCatalogState(payload.items || [], loadedPlugins);

    pluginItems.clear();
    capabilityIndex.clear();

    for (const [pluginId, item] of nextState.pluginItems.entries()) {
      pluginItems.set(pluginId, item);
    }

    for (const [capabilityName, entry] of nextState.capabilityIndex.entries()) {
      capabilityIndex.set(capabilityName, entry);
    }

    log(`Discovered ${pluginItems.size} plugins and ${capabilityIndex.size} capabilities`);
    return Array.from(pluginItems.values());
  }

  async function callCapability(
    capabilityName: string,
    args?: Record<string, unknown>,
  ): Promise<PluginExecutionResult> {
    const entry = capabilityIndex.get(capabilityName);
    if (!entry) {
      return { ok: false, error: `unknown capability: ${capabilityName}` };
    }

    const item = pluginItems.get(entry.pluginId);
    if (!item) {
      return { ok: false, error: `plugin not found: ${entry.pluginId}` };
    }

    try {
      const plugin = await importPlugin(item);
      const handlerEntry = String(entry.capability.entry || "default");
      const exportName = handlerEntry.includes("#")
        ? handlerEntry.split("#")[1]
        : handlerEntry;
      const handler = plugin.module?.[exportName || "default"];
      if (typeof handler !== "function") {
        return { ok: false, error: `handler not found: ${capabilityName}` };
      }

      const result = await handler(cloneArgs(args || {}), {
        api: buildScopedApi(plugin, entry.capability),
        actionId: capabilityName,
      });
      return result || { ok: true };
    } catch (error) {
      log(`Plugin capability failed (${capabilityName}): ${error}`);
      return { ok: false, error: String(error) };
    }
  }

  async function dispatchActions(
    actions: unknown[],
    depsForActions: {
      playMusic: (payload: { url?: string; trackId?: string }) => Promise<void> | void;
      stopMusic: () => Promise<void> | void;
    },
  ): Promise<void> {
    const normalized = (Array.isArray(actions) ? actions : [])
      .map((action, index) => normalizeAction(action as Record<string, unknown>, index))
      .filter((item): item is NormalizedAction => Boolean(item));

    for (const action of normalized) {
      if (action.type === "expression" && action.name) {
        playExpression(action.name);
        continue;
      }

      if (action.type === "motion") {
        playMotion(action.group || "", action.index || 0);
        continue;
      }

      if (action.type === "play_music") {
        await depsForActions.playMusic({
          url: action.url,
          trackId: action.trackId,
        });
        continue;
      }

      if (action.type === "stop_music") {
        await depsForActions.stopMusic();
        continue;
      }

      if (action.type === "plugin.call" && action.capability) {
        await callCapability(action.capability, action.args);
      }
    }
  }

  function getCapabilities() {
    return Array.from(capabilityIndex.entries()).map(([name, entry]) => ({
      name,
      pluginId: entry.pluginId,
      description: entry.capability.description || "",
      permissions: entry.capability.permissions || [],
    }));
  }

  return {
    refreshCatalog,
    dispatchActions,
    callCapability,
    getCapabilities,
  };
}
