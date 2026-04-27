import {
  Box,
  Flex,
  HStack,
  IconButton,
  Stack,
  Text,
} from "@chakra-ui/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  LuEyeOff,
  LuPanelRightOpen,
  LuSettings,
  LuSparkles,
  LuMessageSquarePlus,
  LuUpload,
  LuImage,
  LuSmile,
  LuCamera,
} from "react-icons/lu";
import { useShallow } from "zustand/react/shallow";
import { useConfig } from "@/context/character-config-context";
import { useMode } from "@/context/mode-context";
import { MessageList } from "@/domains/chat/ui/chat-message-list";
import { SharedComposer, captureCameraStill } from "@/domains/composer/ui/shared-composer";
import { PetActionSheet } from "@/domains/model/ui/stage-action-bar";
import { SettingsPanel } from "@/domains/settings/ui/settings-panel";
import {
  fileToComposerAttachment,
  useAppStore,
  selectCurrentSessionMessages,
} from "@/domains/renderer-store";
import { usePetCommands, useSessionCommands } from "@/app/providers/command-provider";
import { shouldScrollPetMessagesToBottom } from "@/runtime/pet-message-scroll-utils.ts";
import { getPetToggleButtonState } from "@/runtime/pet-shell-display-utils.ts";
import {
  getDraggedPetAnchor,
  resolvePetShellHoverState,
} from "@/runtime/pet-shell-interaction-utils.ts";
import { resolveAssistantDisplayName } from "@/runtime/assistant-display-utils.ts";
import { setModelPositionFromScreen } from "@/runtime/live2d-bridge";
import {
  lunariaColors,
  lunariaIconButtonStyles,
  lunariaMutedCardStyles,
  lunariaPanelStyles,
  lunariaPrimaryButtonStyles,
} from "@/theme/lunaria-theme";

export function PetShell({
  onRequestScreenshot,
}: {
  onRequestScreenshot?: () => Promise<void> | void;
}) {
  const { t } = useTranslation();
  const [isHovering, setIsHovering] = useState(false);
  const [isDragging, setIsDragging] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const autoHideTimerRef = useRef<number | null>(null);
  const shellRef = useRef<HTMLDivElement | null>(null);
  const messageViewportRef = useRef<HTMLDivElement | null>(null);
  const dragPointerRef = useRef<{ x: number; y: number } | null>(null);
  const dragAnchorRef = useRef({ x: 0, y: 0 });
  const dragMovedRef = useRef(false);
  const previousScrollSnapshotRef = useRef({
    surface: null as "hidden" | "chat" | "settings" | "plus" | null,
    messageCount: 0,
    latestMessageId: null as string | null,
    expanded: false,
  });
  const { mode } = useMode();
  const { confName } = useConfig();
  const { createNewSession } = useSessionCommands();
  const { startScreenshotSelection } = usePetCommands();
  const backendUrl = useAppStore((state) => state.backendUrl);
  const manifest = useAppStore((state) => state.manifest);
  const connectionState = useAppStore((state) => state.connectionState);
  const currentMessages = useAppStore(selectCurrentSessionMessages);
  const currentSessionId = useAppStore((state) => state.currentSessionId);
  const streamingMessage = useAppStore((state) => state.streamingMessage);
  const assistantDisplayName = resolveAssistantDisplayName({
    configName: confName,
    manifestName: manifest?.model.name,
  });
  const {
    petSurface,
    petPlusView,
    petExpanded,
    petAutoHideSeconds,
    petAnchor,
    petAnchorLocked,
    setPetSurface,
    setPetPlusView,
    setPetExpanded,
    setPetAnchor,
    setPetAnchorLocked,
    addComposerAttachment,
  } = useAppStore(useShallow((state) => ({
    petSurface: state.petSurface,
    petPlusView: state.petPlusView,
    petExpanded: state.petExpanded,
    petAutoHideSeconds: state.petAutoHideSeconds,
    petAnchor: state.petAnchor,
    petAnchorLocked: state.petAnchorLocked,
    setPetSurface: state.setPetSurface,
    setPetPlusView: state.setPetPlusView,
    setPetExpanded: state.setPetExpanded,
    setPetAnchor: state.setPetAnchor,
    setPetAnchorLocked: state.setPetAnchorLocked,
    addComposerAttachment: state.addComposerAttachment,
  })));

  const visibleMessages = useMemo(
    () => currentMessages.slice(-8),
    [currentMessages],
  );

  useEffect(() => {
    const nextSnapshot = {
      surface: petSurface,
      messageCount: visibleMessages.length,
      latestMessageId: visibleMessages[visibleMessages.length - 1]?.id || null,
      expanded: petExpanded,
    };

    if (shouldScrollPetMessagesToBottom({
      previousSurface: previousScrollSnapshotRef.current.surface,
      nextSurface: nextSnapshot.surface,
      previousMessageCount: previousScrollSnapshotRef.current.messageCount,
      nextMessageCount: nextSnapshot.messageCount,
      previousLatestMessageId: previousScrollSnapshotRef.current.latestMessageId,
      nextLatestMessageId: nextSnapshot.latestMessageId,
      previousExpanded: previousScrollSnapshotRef.current.expanded,
      nextExpanded: nextSnapshot.expanded,
    })) {
      requestAnimationFrame(() => {
        const element = messageViewportRef.current;
        if (element) {
          element.scrollTop = element.scrollHeight;
        }
      });
    }

    previousScrollSnapshotRef.current = nextSnapshot;
  }, [petExpanded, petSurface, visibleMessages]);

  const syncAnchor = useCallback(async () => {
    if (mode !== "pet") {
      return;
    }

    try {
      const bounds = await window.api?.getPetOverlayBounds?.();
      if (!bounds) {
        return;
      }

      const centerX = bounds.workArea.x - bounds.virtualBounds.x + bounds.workArea.width / 2;
      const centerY = bounds.workArea.y - bounds.virtualBounds.y + bounds.workArea.height / 2;

      const adapter = (window as any).getLAppAdapter?.();
      const model = adapter?.getModel();
      if (model && model.x === undefined) {
        // Move the WebGL 0,0 center to the exact pixel coordinate of the primary display
        setModelPositionFromScreen(centerX, centerY);
      }

    } catch (error) {
      console.warn("Failed to sync pet anchor:", error);
    }
  }, [mode]);

  useEffect(() => {
    void syncAnchor();
    window.addEventListener("resize", syncAnchor);
    return () => window.removeEventListener("resize", syncAnchor);
  }, [syncAnchor]);

  useEffect(() => {
    if (mode === "pet" || !petAnchorLocked) {
      return;
    }

    setPetAnchorLocked(false);
  }, [mode, petAnchorLocked, setPetAnchorLocked]);

  useEffect(() => {
    if (mode !== "pet") {
      return undefined;
    }

    if (isHovering || petSurface === "hidden" || petAutoHideSeconds <= 0) {
      if (autoHideTimerRef.current) {
        window.clearTimeout(autoHideTimerRef.current);
        autoHideTimerRef.current = null;
      }
      return undefined;
    }

    autoHideTimerRef.current = window.setTimeout(() => {
      const nextHovering = resolvePetShellHoverState({
        petSurface: "hidden",
        isHovering,
      });
      setIsHovering(nextHovering);
      window.api?.updateComponentHover?.("pet-shell", nextHovering);
      setPetSurface("hidden");
    }, petAutoHideSeconds * 1000);

    return () => {
      if (autoHideTimerRef.current) {
        window.clearTimeout(autoHideTimerRef.current);
        autoHideTimerRef.current = null;
      }
    };
  }, [isHovering, mode, petAutoHideSeconds, petSurface, setPetSurface]);

  const setHovering = (value: boolean) => {
    setIsHovering(value);
    window.api?.updateComponentHover?.("pet-shell", value);
  };

  const hidePetSurface = useCallback(() => {
    const nextHovering = resolvePetShellHoverState({
      petSurface: "hidden",
      isHovering,
    });
    setIsHovering(nextHovering);
    window.api?.updateComponentHover?.("pet-shell", nextHovering);
    setPetSurface("hidden");
  }, [isHovering, setPetSurface]);

  const startDragging = useCallback((event: React.PointerEvent) => {
    if (mode !== "pet") {
      return;
    }
    // Only respond to primary pointer button (left mouse)
    if (event.button !== undefined && event.button !== 0) {
      return;
    }

    // Explicitly tell Electron to not ignore mouse events during drag
    // This is needed because setIgnoreMouseEvents may be active
    window.api?.setIgnoreMouseEvents(false);

    dragPointerRef.current = { x: event.clientX, y: event.clientY };
    dragAnchorRef.current = petAnchor;
    dragMovedRef.current = false;
    setIsDragging(true);

    const handleMove = (moveEvent: PointerEvent) => {
      if (!dragPointerRef.current) return;

      const movedEnough =
        Math.abs(moveEvent.clientX - dragPointerRef.current.x) > 3 ||
        Math.abs(moveEvent.clientY - dragPointerRef.current.y) > 3;

      if (!dragMovedRef.current && movedEnough) {
        dragMovedRef.current = true;
        setPetAnchorLocked(true);
      }

      if (!dragMovedRef.current) return;

      const nextAnchor = getDraggedPetAnchor({
        startAnchor: dragAnchorRef.current,
        dragStart: dragPointerRef.current,
        pointer: { x: moveEvent.clientX, y: moveEvent.clientY },
      });
      setPetAnchor(nextAnchor);
    };

    const handleUp = (upEvent: PointerEvent) => {
      window.removeEventListener("pointermove", handleMove, true);
      window.removeEventListener("pointerup", handleUp, true);
      dragPointerRef.current = null;
      setIsDragging(false);

      const element = shellRef.current;
      if (element) {
        const rect = element.getBoundingClientRect();
        const isInside =
          upEvent.clientX >= rect.left &&
          upEvent.clientX <= rect.right &&
          upEvent.clientY >= rect.top &&
          upEvent.clientY <= rect.bottom;
        setHovering(isInside);
      } else {
        setHovering(false);
      }
    };

    window.addEventListener("pointermove", handleMove, true);
    window.addEventListener("pointerup", handleUp, true);
  }, [mode, petAnchor, setPetAnchor, setPetAnchorLocked]);

  const handleToggleClick = useCallback(() => {
    if (dragMovedRef.current) {
      dragMovedRef.current = false;
      return;
    }

    if (petSurface === "hidden") {
      setPetSurface("chat");
    } else {
      hidePetSurface();
    }
    setPetPlusView("root");
  }, [hidePetSurface, petSurface, setPetPlusView, setPetSurface]);

  const handleUpload = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files || []);
    for (const file of files) {
      try {
        const attachment = await fileToComposerAttachment(file);
        addComposerAttachment(attachment);
      } catch (error) {
        console.warn("Failed to add pet attachment:", error);
      }
    }
    event.target.value = "";
    setPetSurface("chat");
  };

  const handleCamera = async () => {
    const file = await captureCameraStill();
    if (file) {
      addComposerAttachment(await fileToComposerAttachment(file));
      setPetSurface("chat");
    }
  };

  const handleScreenshot = async () => {
    if (onRequestScreenshot) {
      await onRequestScreenshot();
      setPetSurface("chat");
      return;
    }

    await startScreenshotSelection();
    setPetSurface("chat");
  };

  const cardWidth = petExpanded ? "440px" : "360px";
  const toggleButtonState = getPetToggleButtonState(petSurface);

  return (
    <Box
      ref={shellRef}
      position="absolute"
      left={`${petAnchor.x}px`}
      top={`${petAnchor.y}px`}
      zIndex={1200}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => {
        if (!isDragging) {
          setHovering(false);
        }
      }}
    >
      <HStack align="start" gap="4">
        <Stack align="start" gap="3">
        <Box
          onPointerDown={startDragging}
          cursor={isDragging ? "grabbing" : "grab"}
          style={{ touchAction: "none" }}
          userSelect="none"
        >
          <IconButton
            aria-label={toggleButtonState.ariaLabel}
            {...lunariaPrimaryButtonStyles}
            w="52px"
            h="52px"
            minW="52px"
            p="0"
            onClick={handleToggleClick}
          >
            <LuSparkles />
          </IconButton>
        </Box>

        {petSurface !== "hidden" && (
          <Box
            w={`min(${cardWidth}, calc(100vw - 24px))`}
            {...lunariaPanelStyles}
            overflow="hidden"
          >
            <Flex
              align="center"
              justify="space-between"
              px="4"
              py="3"
              borderBottom="1px solid"
              borderColor={lunariaColors.border}
              color={lunariaColors.text}
              cursor={isDragging ? "grabbing" : "grab"}
              style={{ touchAction: "none" }}
              userSelect="none"
              onPointerDown={(event) => {
                if ((event.target as HTMLElement).closest("button")) {
                  return;
                }
                startDragging(event);
              }}
            >
              <Box>
                <Text fontSize="sm" fontWeight="700" color={lunariaColors.heading}>
                  {assistantDisplayName}
                </Text>
              </Box>
              <HStack gap="1">
                <IconButton
                  aria-label={t("common.settings")}
                  size="sm"
                  {...lunariaIconButtonStyles}
                  onClick={() => {
                    setPetSurface(petSurface === "settings" ? "chat" : "settings");
                    setPetPlusView("root");
                  }}
                >
                  <LuSettings />
                </IconButton>
                <IconButton
                  aria-label={t("common.expand")}
                  size="sm"
                  {...lunariaIconButtonStyles}
                  onClick={() => setPetExpanded(!petExpanded)}
                >
                  <LuPanelRightOpen />
                </IconButton>
                <IconButton
                  aria-label={t("common.hide")}
                  size="sm"
                  {...lunariaIconButtonStyles}
                  onClick={hidePetSurface}
                >
                  <LuEyeOff />
                </IconButton>
              </HStack>
            </Flex>

            <Box px="4" py="3">
              <Box
                ref={messageViewportRef}
                maxH={petExpanded ? "360px" : "220px"}
                overflowY="auto"
                overflowX="hidden"
                className="custom-scrollbar"
              >
                <MessageList
                  messages={visibleMessages}
                  backendUrl={backendUrl}
                  assistantName={assistantDisplayName}
                  compact
                  variant="pet"
                  currentSessionId={currentSessionId}
                  streamingMessage={streamingMessage}
                />
              </Box>

              <Box mt="4">
                <SharedComposer
                  compact
                  showPlusButton
                  onPlusClick={() => {
                    if (petSurface === "plus") {
                      setPetSurface("chat");
                    } else {
                      setPetSurface("plus");
                      setPetPlusView("root");
                    }
                  }}
                />
              </Box>

              {petSurface === "plus" && petPlusView === "root" && (
                <Flex
                  mt="3"
                  wrap="wrap"
                  gap="3"
                  p="3"
                  justify="center"
                  {...lunariaMutedCardStyles}
                >
                  <IconButton
                    aria-label={t("shell.newSession")}
                    size="md"
                    {...lunariaIconButtonStyles}
                    onClick={() => {
                      void createNewSession();
                      setPetSurface("chat");
                      setPetPlusView("root");
                    }}
                  >
                    <LuMessageSquarePlus />
                  </IconButton>
                  <IconButton aria-label={t("shell.upload")} size="md" {...lunariaIconButtonStyles} onClick={() => fileInputRef.current?.click()}>
                    <LuUpload />
                  </IconButton>
                  <IconButton aria-label={t("shell.camera")} size="md" {...lunariaIconButtonStyles} onClick={() => void handleCamera()}>
                    <LuCamera />
                  </IconButton>
                  <IconButton aria-label={t("shell.screenshot")} size="md" {...lunariaIconButtonStyles} onClick={() => void handleScreenshot()}>
                    <LuImage />
                  </IconButton>
                  <IconButton
                    aria-label={t("shell.actions")}
                    size="md"
                    {...lunariaIconButtonStyles}
                    onClick={() => setPetPlusView("actions")}
                  >
                    <LuSmile />
                  </IconButton>
                </Flex>
              )}

              {petSurface === "plus" && petPlusView === "actions" && (
                <PetActionSheet onBack={() => setPetPlusView("root")} />
              )}
            </Box>
          </Box>
        )}
      </Stack>

      {petSurface === "settings" && (
        <Box w="340px" zIndex={100}>
          <SettingsPanel pet />
        </Box>
      )}
      </HStack>

      <input
        ref={fileInputRef}
        type="file"
        multiple
        accept="image/*,audio/*,video/*,.pdf,.txt,.md,.json,.zip"
        hidden
        onChange={handleUpload}
      />
    </Box>
  );
}
