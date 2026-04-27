import { useAutomationStore } from "@/domains/automation/store";
import {
  attachmentToChatInput,
  createComposerAttachmentId,
  dataUrlToComposerAttachment,
  dataUrlToFile,
  fileToComposerAttachment,
  useComposerStore,
} from "@/domains/composer/store";
import { selectCurrentSessionMessages as selectCurrentSessionChatMessages, useChatStore } from "@/domains/chat/store";
import { getQuickActionLabel, useModelStore } from "@/domains/model/store";
import { usePetStore } from "@/domains/pet/store";
import { usePluginStore } from "@/domains/plugin/store";
import { useSessionStore } from "@/domains/session/store";
import { useSettingsStore } from "@/domains/settings/store";
import type { ComposerAttachment, RuntimeRect } from "@/domains/types";
import { useVoiceStore } from "@/domains/voice/store";
import { useShellStore } from "@/app/shell/shell-store";

type LegacyRendererState = ReturnType<typeof getLegacyRendererState>;

function getLegacyRendererState() {
  const session = useSessionStore.getState();
  const chat = useChatStore.getState();
  const composer = useComposerStore.getState();
  const model = useModelStore.getState();
  const settings = useSettingsStore.getState();
  const pet = usePetStore.getState();
  const shell = useShellStore.getState();
  const automation = useAutomationStore.getState();
  const plugin = usePluginStore.getState();
  const voice = useVoiceStore.getState();

  return {
    ...session,
    ...chat,
    ...composer,
    ...model,
    ...settings,
    ...pet,
    ...shell,
    ...automation,
    ...plugin,
    ...voice,
  };
}

function applyLegacyPartial(partial: Partial<LegacyRendererState>) {
  const sessionPatch: Partial<ReturnType<typeof useSessionStore.getState>> = {};
  const chatPatch: Partial<ReturnType<typeof useChatStore.getState>> = {};
  const composerPatch: Partial<ReturnType<typeof useComposerStore.getState>> = {};
  const modelPatch: Partial<ReturnType<typeof useModelStore.getState>> = {};
  const settingsPatch: Partial<ReturnType<typeof useSettingsStore.getState>> = {};
  const petPatch: Partial<ReturnType<typeof usePetStore.getState>> = {};
  const shellPatch: Partial<ReturnType<typeof useShellStore.getState>> = {};
  const automationPatch: Partial<ReturnType<typeof useAutomationStore.getState>> = {};
  const pluginPatch: Partial<ReturnType<typeof usePluginStore.getState>> = {};
  const voicePatch: Partial<ReturnType<typeof useVoiceStore.getState>> = {};

  for (const [key, value] of Object.entries(partial)) {
    switch (key) {
      case "backendUrl":
      case "sessions":
      case "currentSessionId":
      case "connectionState":
      case "lastEventSeq":
        (sessionPatch as Record<string, unknown>)[key] = value;
        break;
      case "messagesBySession":
      case "streamingMessage":
        (chatPatch as Record<string, unknown>)[key] = value;
        break;
      case "composerDraft":
      case "composerAttachments":
        (composerPatch as Record<string, unknown>)[key] = value;
        break;
      case "manifest":
      case "quickActions":
      case "motions":
      case "expressions":
      case "persistentToggles":
      case "persistentToggleState":
      case "currentModelBounds":
        (modelPatch as Record<string, unknown>)[key] = value;
        break;
      case "currentProviderId":
      case "providerFieldValues":
      case "providerFieldManifestValues":
      case "ttsEnabled":
      case "ttsProvider":
      case "focusCenterByModel":
      case "backgroundByMode":
        (settingsPatch as Record<string, unknown>)[key] = value;
        break;
      case "petSurface":
      case "petPlusView":
      case "petExpanded":
      case "petAutoHideSeconds":
      case "petAnchor":
      case "petAnchorLocked":
        (petPatch as Record<string, unknown>)[key] = value;
        break;
      case "stageActionPanelOpen":
      case "screenshotOverlay":
        (shellPatch as Record<string, unknown>)[key] = value;
        break;
      case "automation":
      case "automationRuleState":
      case "automationLogs":
        (automationPatch as Record<string, unknown>)[key] = value;
        break;
      case "plugins":
      case "pluginLoadState":
      case "pluginLogs":
        (pluginPatch as Record<string, unknown>)[key] = value;
        break;
      case "aiState":
      case "backendSynthComplete":
      case "subtitle":
      case "showSubtitle":
      case "forceIgnoreMouse":
        (voicePatch as Record<string, unknown>)[key] = value;
        break;
      default:
        break;
    }
  }

  if (Object.keys(sessionPatch).length) useSessionStore.setState(sessionPatch);
  if (Object.keys(chatPatch).length) useChatStore.setState(chatPatch);
  if (Object.keys(composerPatch).length) useComposerStore.setState(composerPatch);
  if (Object.keys(modelPatch).length) useModelStore.setState(modelPatch);
  if (Object.keys(settingsPatch).length) useSettingsStore.setState(settingsPatch);
  if (Object.keys(petPatch).length) usePetStore.setState(petPatch);
  if (Object.keys(shellPatch).length) useShellStore.setState(shellPatch);
  if (Object.keys(automationPatch).length) useAutomationStore.setState(automationPatch);
  if (Object.keys(pluginPatch).length) usePluginStore.setState(pluginPatch);
  if (Object.keys(voicePatch).length) useVoiceStore.setState(voicePatch);
}

type Selector<T> = (state: LegacyRendererState) => T;

interface AggregatedStoreHook {
  <T>(selector: Selector<T>): T;
  getState: () => LegacyRendererState;
  setState: (updater: Partial<LegacyRendererState> | ((current: LegacyRendererState) => Partial<LegacyRendererState>)) => void;
}

const useAggregatedRendererStore = ((selector) => {
  const session = useSessionStore((state) => state);
  const chat = useChatStore((state) => state);
  const composer = useComposerStore((state) => state);
  const model = useModelStore((state) => state);
  const settings = useSettingsStore((state) => state);
  const pet = usePetStore((state) => state);
  const shell = useShellStore((state) => state);
  const automation = useAutomationStore((state) => state);
  const plugin = usePluginStore((state) => state);
  const voice = useVoiceStore((state) => state);

  return selector({
    ...session,
    ...chat,
    ...composer,
    ...model,
    ...settings,
    ...pet,
    ...shell,
    ...automation,
    ...plugin,
    ...voice,
  });
}) as AggregatedStoreHook;

useAggregatedRendererStore.getState = getLegacyRendererState;
useAggregatedRendererStore.setState = (updater) => {
  const partial = typeof updater === "function"
    ? updater(getLegacyRendererState())
    : updater;
  applyLegacyPartial(partial);
};

export const useAppStore = useAggregatedRendererStore;

export function selectCurrentSessionMessages(state: LegacyRendererState) {
  return selectCurrentSessionChatMessages({
    messagesBySession: state.messagesBySession,
    streamingMessage: state.streamingMessage,
    setMessagesForSession: useChatStore.getState().setMessagesForSession,
    commitMessagesForSession: useChatStore.getState().commitMessagesForSession,
    appendMessageForSession: useChatStore.getState().appendMessageForSession,
    upsertMessageForSession: useChatStore.getState().upsertMessageForSession,
    setStreamingMessage: useChatStore.getState().setStreamingMessage,
  }, state.currentSessionId);
}

export {
  attachmentToChatInput,
  createComposerAttachmentId,
  dataUrlToComposerAttachment,
  dataUrlToFile,
  fileToComposerAttachment,
  getQuickActionLabel,
};
export type { ComposerAttachment, RuntimeRect };
