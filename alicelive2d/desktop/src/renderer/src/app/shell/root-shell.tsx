import {
  Box,
  Button,
  Flex,
  HStack,
  IconButton,
  Stack,
  Text,
} from "@chakra-ui/react";
import { useEffect, useMemo, useRef, useState, type ChangeEvent, type CSSProperties } from "react";
import { useTranslation } from "react-i18next";
import {
  FiLayers,
} from "react-icons/fi";
import {
  LuCamera,
  LuImage,
  LuMessageSquarePlus,
  LuSmile,
  LuUpload,
  LuVolume2,
  LuVolumeX,
} from "react-icons/lu";
import { useAppStore, getQuickActionLabel, selectCurrentSessionMessages } from "@/domains/renderer-store";
import { useSettingsStore } from "@/domains/settings/store";
import { CurrentSessionMessageList } from "@/domains/chat/ui/chat-message-list";
import { getPetShellBackgroundStyle } from "@/runtime/pet-overlay-utils.ts";
import {
  getLunariaDocumentBackground,
  getNextWindowSidebarPanel,
  shouldShowWindowSidebarSection,
} from "@/runtime/window-shell-utils.ts";
import { getLunariaScrollbarStyles } from "@/runtime/chat-shell-utils.ts";
import { formatChatMessageTimestamp } from "@/runtime/chat-time-utils.ts";
import { Live2D } from "@/platform/live2d/ui/live2d-canvas";
import TitleBar from "@/platform/electron/ui/title-bar";
import { useConfig } from "@/context/character-config-context";
import { resolveAssistantDisplayName } from "@/runtime/assistant-display-utils.ts";
import { useMode } from "@/context/mode-context";
import ScreenshotSelectionOverlay from "@/app/shell/screenshot-selection-overlay";
import { SharedComposer as BottomComposer, captureCameraStill } from "@/domains/composer/ui/shared-composer";
import {
  useAutomationCommands,
  useChatCommands,
  useComposerCommands,
  useModelCommands,
  usePetCommands,
  useSessionCommands,
} from "@/app/providers/command-provider";
import { PetShell as LunariaPetShell } from "@/domains/pet/ui/pet-shell";
import { SettingsPanel } from "@/domains/settings/ui/settings-panel";
import {
  lunariaBackgroundImage,
  lunariaCompactPillButtonStyles,
  lunariaColors,
  lunariaEyebrowStyles,
  lunariaHeadingStyles,
  lunariaIconButtonStyles,
  lunariaMutedCardStyles,
  lunariaPanelStyles,
  lunariaSecondaryButtonStyles,
  getLunariaIntentStyles,
} from "@/theme/lunaria-theme";

function resolveConnectionIntent(connectionState: string): "success" | "info" | "danger" | "warning" {
  const normalized = String(connectionState || "").toLowerCase();
  if (normalized.includes("connected") || normalized.includes("open")) {
    return "success";
  }
  if (normalized.includes("connecting")) {
    return "info";
  }
  if (normalized.includes("error") || normalized.includes("closed")) {
    return "danger";
  }
  return "warning";
}

const lunariaScrollbarStyles = getLunariaScrollbarStyles();

const vnFloatInKeyframes = `
  @keyframes vnBubbleFloatInLeft {
    from {
      opacity: 0;
      transform: translate3d(-8px, 10px, 0) scale(0.985);
    }
    to {
      opacity: 1;
      transform: translate3d(0, 0, 0) scale(1);
    }
  }

  @keyframes vnBubbleFloatInRight {
    from {
      opacity: 0;
      transform: translate3d(8px, -10px, 0) scale(0.985);
    }
    to {
      opacity: 1;
      transform: translate3d(0, 0, 0) scale(1);
    }
  }
`;

function ActionPanel({
  pet = false,
}: {
  pet?: boolean;
}) {
  const {
    executeQuickAction,
    executeMotion,
    executeExpression,
  } = useModelCommands();
  const { t } = useTranslation();
  const quickActions = useAppStore((state) => state.quickActions);
  const motions = useAppStore((state) => state.motions);
  const expressions = useAppStore((state) => state.expressions);
  const persistentToggles = useAppStore((state) => state.persistentToggles);
  const persistentToggleState = useAppStore((state) => state.persistentToggleState);
  const togglePersistent = useAppStore((state) => state.togglePersistentToggle);


  const sectionTitle = (label: string) => (
    <Text {...lunariaEyebrowStyles}>
      {label}
    </Text>
  );

  const actionButton = (label: string, onClick: () => void, key: string, active = false) => (
    <Button
      key={key}
      size="xs"
      {...lunariaCompactPillButtonStyles}
      bg={active ? lunariaColors.primarySoft : lunariaSecondaryButtonStyles.bg}
      color={active ? lunariaColors.primaryStrong : lunariaColors.text}
      borderColor={active ? "rgba(220, 141, 121, 0.3)" : lunariaColors.border}
      onClick={onClick}
    >
      {label}
    </Button>
  );

  return (
    <Stack
      gap="3.5"
      py={pet ? "3" : "2"}
      maxH={pet ? "42vh" : "34vh"}
      overflowY="auto"
      css={lunariaScrollbarStyles}
    >
      <Box>
        {sectionTitle(t("stageActions.quickActions"))}
        <Flex wrap="wrap" gap="2" mt="2.5">
          {quickActions.map((action, index) => actionButton(
            getQuickActionLabel(action),
            () => void executeQuickAction(action as never),
            `quick_${index}`,
          ))}
        </Flex>
      </Box>

      {Object.keys(persistentToggles).length ? (
        <Box>
          {sectionTitle(t("stageActions.persistent"))}
          <Flex wrap="wrap" gap="2" mt="2.5">
            {Object.entries(persistentToggles).map(([key, config]) => actionButton(
              persistentToggleState[key]
                ? (config.onLabel || key)
                : (config.offLabel || key),
              () => togglePersistent(key),
              `toggle_${key}`,
              !!persistentToggleState[key],
            ))}
          </Flex>
        </Box>
      ) : null}

      <Box>
        {sectionTitle(t("stageActions.motions"))}
        <Flex wrap="wrap" gap="2" mt="2.5">
          {motions.map((motion, index) => actionButton(
            motion.label || `${motion.group}:${motion.index}`,
            () => void executeMotion(motion.group, motion.index),
            `motion_${index}`,
          ))}
        </Flex>
      </Box>

      <Box>
        {sectionTitle(t("stageActions.expressions"))}
        <Flex wrap="wrap" gap="2" mt="2.5">
          {expressions.map((expression, index) => actionButton(
            expression.name,
            () => void executeExpression(expression.name),
            `expression_${index}`,
          ))}
        </Flex>
      </Box>
    </Stack>
  );
}

function SessionsPanel() {
  const sessions = useAppStore((state) => state.sessions);
  const currentSessionId = useAppStore((state) => state.currentSessionId);
  const { loadSession } = useSessionCommands();

  return (
    <Stack gap="2.5" maxH="200px" overflowY="auto" css={lunariaScrollbarStyles} pt="2">
      {sessions.map((session) => {
        const selected = session.id === currentSessionId;
        return (
          <Button
            key={session.id}
            justifyContent="space-between"
            h="42px"
            {...lunariaSecondaryButtonStyles}
            bg={selected ? "rgba(246, 216, 207, 0.48)" : "transparent"}
            color={selected ? lunariaColors.primaryStrong : lunariaColors.text}
            borderColor={selected ? "rgba(220, 141, 121, 0.26)" : "transparent"}
            onClick={() => void loadSession(session.id)}
          >
            <Text whiteSpace="nowrap" overflow="hidden" textOverflow="ellipsis" maxW="220px">
              {session.name || session.id}
            </Text>
            <Text fontSize="11px" color={lunariaColors.textSubtle}>
              {formatChatMessageTimestamp(session.updatedAt)}
            </Text>
          </Button>
        );
      })}
    </Stack>
  );
}

function WindowShell() {
  const { createNewSession } = useSessionCommands();
  const { confName } = useConfig();
  const { addFiles, startScreenshotSelection } = useComposerCommands();
  const { setMode, isElectron } = useMode();
  const { t } = useTranslation();
  const [sidebarPanel, setSidebarPanel] = useState<"sessions" | "settings" | null>(null);
  const [windowPlusOpen, setWindowPlusOpen] = useState(false);
  const [viewportSize, setViewportSize] = useState({
    width: typeof window !== "undefined" ? window.innerWidth : 1280,
    height: typeof window !== "undefined" ? window.innerHeight : 720,
  });
  const windowFileInputRef = useRef<HTMLInputElement>(null);
  const manifest = useAppStore((state) => state.manifest);
  const currentSessionId = useAppStore((state) => state.currentSessionId);
  const messages = useAppStore(selectCurrentSessionMessages);
  const stageActionPanelOpen = useAppStore((state) => state.stageActionPanelOpen);
  const setStageActionPanelOpen = useAppStore((state) => state.setStageActionPanelOpen);
  const subtitle = useAppStore((state) => state.subtitle);
  const background = useAppStore((state) => state.backgroundByMode.window);
  const connectionState = useAppStore((state) => state.connectionState);
  const sessionsOpen = shouldShowWindowSidebarSection(sidebarPanel, "sessions");
  const settingsOpen = shouldShowWindowSidebarSection(sidebarPanel, "settings");
  const isPortraitLayout = !isElectron && viewportSize.height > viewportSize.width;
  const isMobileWeb = !isElectron && viewportSize.width <= 960;
  const connectionTone = getLunariaIntentStyles(resolveConnectionIntent(connectionState));
  const assistantDisplayName = resolveAssistantDisplayName({
    configName: confName,
    manifestName: manifest?.model.name,
  });

  const latestUserMessage = useMemo(
    () => [...messages].reverse().find((message) => message.role === "user" && message.text?.trim()),
    [messages],
  );
  const latestAssistantMessage = useMemo(
    () => [...messages].reverse().find((message) => message.role === "assistant" && message.text?.trim()),
    [messages],
  );

  const userBubbleAnimation = useMemo<CSSProperties>(
    () => ({ animation: "vnBubbleFloatInLeft 260ms ease-out" }),
    [latestUserMessage?.id, latestUserMessage?.text],
  );
  const assistantBubbleAnimation = useMemo<CSSProperties>(
    () => ({ animation: "vnBubbleFloatInRight 280ms ease-out" }),
    [latestAssistantMessage?.id, latestAssistantMessage?.text],
  );

  const formatBubbleTimestamp = (value: string | number | Date | null | undefined) => {
    if (!value) return "";

    let date: Date | null = null;

    if (value instanceof Date) {
      date = value;
    } else if (typeof value === "number") {
      date = new Date(value < 1e12 ? value * 1000 : value);
    } else if (typeof value === "string") {
      const trimmed = value.trim();
      if (/^\d+$/.test(trimmed)) {
        const numeric = Number(trimmed);
        date = new Date(numeric < 1e12 ? numeric * 1000 : numeric);
      } else {
        date = new Date(trimmed);
      }
    }

    if (!date || Number.isNaN(date.getTime())) {
      return formatChatMessageTimestamp(value as never);
    }

    const month = String(date.getMonth() + 1).padStart(2, "0");
    const day = String(date.getDate()).padStart(2, "0");
    const hours = String(date.getHours()).padStart(2, "0");
    const minutes = String(date.getMinutes()).padStart(2, "0");
    const seconds = String(date.getSeconds()).padStart(2, "0");
    return `${month}-${day} ${hours}:${minutes}:${seconds}`;
  };

  useEffect(() => {
    const handleResize = () => {
      setViewportSize({
        width: window.innerWidth,
        height: window.innerHeight,
      });
    };

    handleResize();
    window.addEventListener("resize", handleResize);
    return () => window.removeEventListener("resize", handleResize);
  }, []);

  const handleWindowUpload = (event: ChangeEvent<HTMLInputElement>) => {
    const files = event.target.files;
    if (files?.length) {
      void addFiles(files);
    }
    event.target.value = "";
    setWindowPlusOpen(false);
  };

  const handleWindowCamera = async () => {
    const file = await captureCameraStill();
    if (file) {
      await addFiles([file]);
    }
    setWindowPlusOpen(false);
  };

  const handleWindowScreenshot = async () => {
    await startScreenshotSelection();
    setWindowPlusOpen(false);
  };

  return (
    <Flex h="100dvh" w="100vw" bg="transparent" overflow="hidden" position="relative">
      <Box position="fixed" top={isPortraitLayout ? "14px" : "24px"} right={isPortraitLayout ? "14px" : "24px"} zIndex="30" pointerEvents="none">
        <Text
          px="3.5"
          py="2"
          borderRadius="999px"
          bg={connectionTone.bg}
          color={connectionTone.color}
          border="1px solid"
          borderColor={connectionTone.borderColor}
          fontSize="12px"
          fontWeight="700"
        >
          {connectionState}
        </Text>
      </Box>

      <style>{vnFloatInKeyframes}</style>

      <Flex
        flex="1"
        position="relative"
        overflow="hidden"
        direction="column"
        borderRadius={isElectron ? "26px" : "0"}
        border="1px solid"
        borderColor={lunariaColors.border}
        boxShadow="0 24px 64px rgba(121, 93, 77, 0.14)"
        bg={lunariaColors.appBgSoft}
      >
        {isElectron ? <TitleBar /> : null}

        <Box
          flex="1"
          minH="0"
          position="relative"
          overflow="hidden"
        >
          <Box
            position="absolute"
            inset={isElectron ? "30px 0 0 0" : "0"}
            backgroundImage={background ? `url(${background})` : lunariaBackgroundImage}
            backgroundSize="cover"
            backgroundPosition="center"
          >
            <Box
              position="absolute"
              inset="0"
              display="flex"
              alignItems="stretch"
              justifyContent="center"
            >
              <Box flex="1" minW="0" h="100%">
                <Live2D />
              </Box>
            </Box>

          </Box>
        </Box>

        <Box
          position="absolute"
          right={isPortraitLayout ? "14px" : "18px"}
          bottom={isMobileWeb ? "84px" : "88px"}
          zIndex="24"
        >
          <HStack justify="flex-end" align="center" spacing="2">
            {/* TTS button */}
            <IconButton
              aria-label={useAppStore.getState().ttsEnabled ? t("shell.disableTts") : t("shell.enableTts")}
              onClick={() => useAppStore.getState().setTtsEnabled(!useAppStore.getState().ttsEnabled)}
              bg={useAppStore.getState().ttsEnabled ? lunariaColors.primarySoft : lunariaIconButtonStyles.bg}
              color={useAppStore.getState().ttsEnabled ? lunariaColors.primaryStrong : lunariaColors.text}
              {...lunariaIconButtonStyles}
            >
              {useAppStore.getState().ttsEnabled ? <LuVolume2 /> : <LuVolumeX />}
            </IconButton>
            {isElectron ? (
              <IconButton aria-label={t("shell.petMode")} onClick={() => setMode("pet")} {...lunariaIconButtonStyles}><FiLayers /></IconButton>
            ) : null}
          </HStack>
        </Box>

        {!settingsOpen ? (
          <>
            {latestUserMessage?.text ? (
              <Box
                key={`user-bubble-${latestUserMessage.id || latestUserMessage.text}`}
                position="absolute"
                left={isMobileWeb ? "4px" : "8px"}
                bottom={isMobileWeb ? "88px" : "84px"}
                w={isMobileWeb ? "102px" : "112px"}
                minH={isMobileWeb ? "112px" : "132px"}
                px="2.5"
                py="3"
                borderRadius="22px"
                bg="linear-gradient(180deg, rgba(246,242,239,0.38) 0%, rgba(236,231,226,0.2) 100%)"
                border="1px solid"
                borderColor="rgba(154, 140, 130, 0.16)"
                boxShadow="0 10px 24px rgba(88, 70, 60, 0.07)"
                backdropFilter="blur(16px) saturate(110%)"
                zIndex="18"
                style={userBubbleAnimation}
                _before={{
                  content: '""',
                  position: "absolute",
                  inset: "0",
                  borderRadius: "inherit",
                  background: "linear-gradient(180deg, rgba(255,255,255,0.14) 0%, rgba(255,255,255,0) 70%)",
                  pointerEvents: "none",
                }}
              >
                <Text fontSize="9px" letterSpacing="0.08em" color="rgba(92, 84, 78, 0.72)" mb="2" fontWeight="600">{formatBubbleTimestamp(latestUserMessage.createdAt)}</Text>
                <Text noOfLines={5} whiteSpace="pre-wrap" fontSize="13px" lineHeight="1.72" color="rgba(62, 57, 54, 0.88)">{latestUserMessage.text}</Text>
              </Box>
            ) : null}

            {latestAssistantMessage?.text ? (
              <Box
                key={`assistant-bubble-${latestAssistantMessage.id || latestAssistantMessage.text}`}
                position="absolute"
                right={isMobileWeb ? "4px" : "8px"}
                top={isElectron ? "58px" : "60px"}
                w={isMobileWeb ? "108px" : "118px"}
                minH={isMobileWeb ? "126px" : "148px"}
                px="2.5"
                py="3"
                borderRadius="24px"
                bg="linear-gradient(180deg, rgba(255,244,247,0.44) 0%, rgba(248,236,240,0.24) 100%)"
                border="1px solid"
                borderColor="rgba(227, 183, 195, 0.2)"
                boxShadow="0 12px 28px rgba(161, 118, 134, 0.09)"
                backdropFilter="blur(18px) saturate(118%)"
                zIndex="18"
                style={assistantBubbleAnimation}
                _before={{
                  content: '""',
                  position: "absolute",
                  inset: "0",
                  borderRadius: "inherit",
                  background: "linear-gradient(180deg, rgba(255,255,255,0.18) 0%, rgba(255,245,248,0) 72%)",
                  pointerEvents: "none",
                }}
              >
                <Text fontSize="9px" letterSpacing="0.08em" color="rgba(153, 104, 124, 0.72)" mb="2" fontWeight="700">{formatBubbleTimestamp(latestAssistantMessage.createdAt)}</Text>
                <Text noOfLines={5} whiteSpace="pre-wrap" fontSize="13px" lineHeight="1.72" color="rgba(95, 72, 82, 0.92)">{latestAssistantMessage.text}</Text>
              </Box>
            ) : null}
          </>
        ) : null}

        <Box
          borderTop="1px solid"
          borderColor="rgba(176, 144, 122, 0.18)"
          bg="linear-gradient(180deg, rgba(251,247,243,0.72) 0%, rgba(244,236,228,0.82) 100%)"
          backdropFilter="blur(18px)"
          px={isMobileWeb ? "10px" : "16px"}
          py={isMobileWeb ? "8px" : "10px"}
          zIndex="20"
        >
          <Flex direction="column" gap="2">
            <input
              ref={windowFileInputRef}
              type="file"
              hidden
              multiple
              accept="image/*,audio/*,video/*,*/*"
              onChange={handleWindowUpload}
            />

            {!settingsOpen && windowPlusOpen ? (
              <Flex wrap="wrap" gap="3" p="3" justify="center" {...lunariaMutedCardStyles}>
                <IconButton
                  aria-label={t("shell.newSession")}
                  size="md"
                  {...lunariaIconButtonStyles}
                  onClick={() => {
                    void createNewSession();
                    setWindowPlusOpen(false);
                  }}
                >
                  <LuMessageSquarePlus />
                </IconButton>
                <IconButton
                  aria-label={t("shell.upload")}
                  size="md"
                  {...lunariaIconButtonStyles}
                  onClick={() => windowFileInputRef.current?.click()}
                >
                  <LuUpload />
                </IconButton>
                <IconButton
                  aria-label={t("shell.camera")}
                  size="md"
                  {...lunariaIconButtonStyles}
                  onClick={() => void handleWindowCamera()}
                >
                  <LuCamera />
                </IconButton>
                <IconButton
                  aria-label={t("shell.screenshot")}
                  size="md"
                  {...lunariaIconButtonStyles}
                  onClick={() => void handleWindowScreenshot()}
                >
                  <LuImage />
                </IconButton>
                <IconButton
                  aria-label={t("shell.actions")}
                  size="md"
                  {...lunariaIconButtonStyles}
                  onClick={() => {
                    setStageActionPanelOpen(!stageActionPanelOpen);
                    setWindowPlusOpen(false);
                  }}
                >
                  <LuSmile />
                </IconButton>
              </Flex>
            ) : null}

            {!settingsOpen && stageActionPanelOpen ? <ActionPanel /> : null}

            {settingsOpen ? (
              <Box maxH={isMobileWeb ? "42dvh" : "50dvh"} overflow="auto" borderRadius="18px" bg="rgba(255,255,255,0.45)">
                <SettingsPanel />
              </Box>
            ) : (
              <BottomComposer
                compact
                showPlusButton={false}
                showWindowTools={false}
                onPlusClick={() => {
                  setStageActionPanelOpen(false);
                  setWindowPlusOpen((current) => !current);
                }}
                onScreenshotClick={() => void handleWindowScreenshot()}
              />
            )}
          </Flex>
        </Box>
      </Flex>
    </Flex>
  );
}

function PetShell() {
  const { startScreenshotSelection } = usePetCommands();
  const background = useAppStore((state) => state.backgroundByMode.pet);
  const petBackgroundStyle = getPetShellBackgroundStyle(background);

  return (
    <Box
      position="fixed"
      inset="0"
      overflow="hidden"
      {...petBackgroundStyle}
    >
      <Box position="absolute" inset="0">
        <Live2D />
      </Box>

      <LunariaPetShell onRequestScreenshot={() => startScreenshotSelection()} />
    </Box>
  );
}

export default function LunariaShell(): JSX.Element {
  const { mode, isElectron } = useMode();
  const {
    closeScreenshotSelection,
    createPendingCaptureAttachment,
    resolvePendingCaptureAttachment,
    failPendingCaptureAttachment,
  } = useComposerCommands();
  const background = useAppStore((state) => state.backgroundByMode[mode]);
  const screenshotOverlay = useAppStore((state) => state.screenshotOverlay);

  useEffect(() => {
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";
    document.documentElement.style.height = "100%";
    document.body.style.height = "100%";
    const documentBackground = getLunariaDocumentBackground({
      mode,
      hasBackground: Boolean(background),
      transparentWindow: isElectron && mode === "window",
    });
    document.documentElement.style.background = documentBackground;
    document.body.style.background = documentBackground;
  }, [background, isElectron, mode]);

  useEffect(() => {
    if (!window.electron?.ipcRenderer) {
      return undefined;
    }

    const handleToggleForceIgnoreMouse = () => {
      window.api?.toggleForceIgnoreMouse?.();
    };

    window.electron.ipcRenderer.on("toggle-force-ignore-mouse", handleToggleForceIgnoreMouse);

    return () => {
      window.electron?.ipcRenderer.removeListener("toggle-force-ignore-mouse", handleToggleForceIgnoreMouse);
    };
  }, []);

  return (
    <>
      {mode === "pet" ? <PetShell /> : <WindowShell />}
      {screenshotOverlay ? (
        <ScreenshotSelectionOverlay
          fileUrl={screenshotOverlay.fileUrl}
          cleanupToken={screenshotOverlay.cleanupToken}
          filename={screenshotOverlay.filename}
          onCancel={closeScreenshotSelection}
          onCreateCapture={(filename) => createPendingCaptureAttachment(filename)}
          onResolveCapture={(attachmentId, dataUrl, filename) => resolvePendingCaptureAttachment(attachmentId, dataUrl, filename)}
          onFailCapture={(attachmentId) => failPendingCaptureAttachment(attachmentId)}
        />
      ) : null}
    </>
  );
}
