import type {
  LunariaExpression,
  LunariaManifest,
  LunariaMessage,
  LunariaMotion,
  LunariaQuickAction,
  LunariaSession,
} from "@/platform/backend/openclaw-api";

export type PetSurface = "hidden" | "chat" | "settings" | "plus";
export type PetPlusView = "root" | "actions";
export type ConnectionState = "idle" | "connecting" | "open" | "error";
export type AttachmentKind = "image" | "audio" | "video" | "file";

export interface ComposerAttachment {
  id: string;
  kind: AttachmentKind;
  filename: string;
  mimeType: string;
  previewUrl: string;
  source: "base64" | "url";
  data: string;
  file?: File;
  tempFileUrl?: string;
  cleanupToken?: string;
  previewState?: "pending" | "ready" | "error";
}

export interface PersistentToggleConfig {
  key?: string;
  paramId?: string;
  onValue?: number;
  offValue?: number;
  speed?: number;
  triggerWeight?: number;
  resetWeight?: number;
  onLabel?: string;
  offLabel?: string;
}

export interface FocusCenterConfig {
  enabled?: boolean;
  headRatio?: number;
}

export interface RuntimeRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
  width: number;
  height: number;
}

export interface ScreenshotOverlayState {
  fileUrl: string;
  cleanupToken: string;
  filename: string;
}

export interface AutomationRuleConfig {
  enabled: boolean;
  intervalMin: number;
  prompt: string;
}

export interface AutomationMusicConfig {
  allowAiActions: boolean;
  defaultUrl: string;
  volume: number;
  loop: boolean;
}

export interface AutomationConfig {
  enabled: boolean;
  onlyPetMode: boolean;
  proactive: AutomationRuleConfig;
  screenshot: AutomationRuleConfig;
  music: AutomationMusicConfig;
}

export interface AutomationRuleState {
  lastRunAt: number;
  running: boolean;
}

export interface AutomationLogItem {
  id: string;
  timestamp: number;
  timeLabel: string;
  text: string;
  status: "info" | "warn" | "error";
}

export interface StreamingMessage {
  id: string;
  sessionId: string;
  text: string;
  rawText: string;
  createdAt: number;
}

export interface PluginCatalogItem {
  id: string;
  source: "builtin" | "local";
  rootPath: string;
  entryUrl: string;
  manifest: Record<string, unknown>;
}

export type {
  LunariaExpression,
  LunariaManifest,
  LunariaMessage,
  LunariaMotion,
  LunariaQuickAction,
  LunariaSession,
};
