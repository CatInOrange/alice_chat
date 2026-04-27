import {
  Box,
  Button,
  Flex,
  HStack,
  IconButton,
  Input,
  Stack,
} from "@chakra-ui/react";
import {
  type ChangeEvent,
  type ClipboardEvent,
  type DragEvent,
  type KeyboardEvent,
  useMemo,
  useRef,
  useState,
} from "react";
import { useTranslation } from "react-i18next";
import { LuCamera, LuImagePlus, LuPaperclip, LuPlus, LuSend, LuX } from "react-icons/lu";
import { useShallow } from "zustand/react/shallow";
import { useMediaCapture } from "@/hooks/utils/use-media-capture";
import {
  dataUrlToFile,
  fileToComposerAttachment,
  useAppStore,
} from "@/domains/renderer-store";
import { getComposerAction } from "@/runtime/chat-surface-utils.ts";
import { useChatCommands, useComposerCommands } from "@/app/providers/command-provider";
import {
  lunariaColors,
  lunariaIconButtonStyles,
  lunariaPrimaryButtonStyles,
  lunariaSecondaryButtonStyles,
} from "@/theme/lunaria-theme";

function canvasToFile(
  canvas: HTMLCanvasElement,
  filename: string,
  mimeType: string,
  quality: number,
): Promise<File> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (!blob) {
        reject(new Error("Failed to create camera blob"));
        return;
      }
      resolve(new File([blob], filename, { type: mimeType }));
    }, mimeType, quality);
  });
}

export async function captureCameraStill(): Promise<File | null> {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: true,
      audio: false,
    });
    const video = document.createElement("video");
    video.srcObject = stream;
    video.muted = true;
    video.playsInline = true;
    await video.play();

    const canvas = document.createElement("canvas");
    canvas.width = video.videoWidth || 1280;
    canvas.height = video.videoHeight || 720;
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      throw new Error("Failed to create camera canvas context");
    }
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    stream.getTracks().forEach((track) => track.stop());
    return canvasToFile(canvas, "camera.jpg", "image/jpeg", 0.92);
  } catch (error) {
    console.warn("Failed to capture camera still:", error);
    return null;
  }
}

function AttachmentChip({
  attachment,
  onRemove,
}: {
  attachment: {
    id: string;
    previewUrl: string;
    kind: string;
    previewState?: "pending" | "ready" | "error";
  };
  onRemove: () => void;
}) {
  const { t } = useTranslation();
  const isImage = attachment.kind === "image";
  const isPending = attachment.previewState === "pending";
  const isError = attachment.previewState === "error";
  const previewBackground = isImage && !isPending && !isError && attachment.previewUrl
    ? `url(${attachment.previewUrl})`
    : undefined;

  return (
    <Box position="relative" w="56px" h="56px" flexShrink={0}>
      <Flex
        w="56px"
        h="56px"
        overflow="hidden"
        borderRadius="14px"
        border="1px solid"
        borderColor={isError ? "rgba(220, 141, 121, 0.38)" : lunariaColors.border}
        bg={isPending ? "rgba(255, 255, 255, 0.45)" : isError ? lunariaColors.primarySoft : lunariaColors.cardStrong}
        bgImage={previewBackground}
        bgPos="center"
        bgSize="cover"
        align="center"
        justify="center"
        backdropFilter={isPending ? "blur(12px) saturate(0.85)" : undefined}
        filter={isPending ? "saturate(0.82)" : undefined}
        color={isError ? lunariaColors.primaryStrong : lunariaColors.textMuted}
      >
        {!isImage ? <LuPaperclip /> : null}
      </Flex>

      <IconButton
        aria-label={t("composer.removeAttachment")}
        size="2xs"
        position="absolute"
        top="-6px"
        right="-6px"
        minW="20px"
        w="20px"
        h="20px"
        borderRadius="999px"
        bg="rgba(35, 27, 22, 0.78)"
        color="white"
        _hover={{ bg: "rgba(35, 27, 22, 0.92)" }}
        _active={{ bg: "rgba(35, 27, 22, 0.96)" }}
        onClick={onRemove}
      >
        <LuX />
      </IconButton>
    </Box>
  );
}

export function SharedComposer({
  compact = false,
  showWindowTools = false,
  showPlusButton = false,
  onPlusClick,
  onScreenshotClick,
}: {
  compact?: boolean;
  showWindowTools?: boolean;
  showPlusButton?: boolean;
  onPlusClick?: () => void;
  onScreenshotClick?: () => void;
}) {
  const { t } = useTranslation();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [isComposing, setIsComposing] = useState(false);
  const controlSize = compact ? "44px" : "48px";
  const isMobileSized = compact;
  const {
    composerDraft,
    composerAttachments,
    connectionState,
    streamingMessage,
    setComposerDraft,
    addComposerAttachment,
    removeComposerAttachment,
  } = useAppStore(useShallow((state) => ({
    composerDraft: state.composerDraft,
    composerAttachments: state.composerAttachments,
    connectionState: state.connectionState,
    streamingMessage: state.streamingMessage,
    setComposerDraft: state.setComposerDraft,
    addComposerAttachment: state.addComposerAttachment,
    removeComposerAttachment: state.removeComposerAttachment,
  })));
  const { interrupt, sendComposerMessage } = useChatCommands();
  const { addCaptureDataUrl } = useComposerCommands();
  const { captureAllMedia } = useMediaCapture();

  const hasUnresolvedAttachments = useMemo(() => (
    composerAttachments.some((attachment) => (
      attachment.previewState === "pending" || attachment.previewState === "error"
    ))
  ), [composerAttachments]);
  const hasContent = useMemo(() => (
    composerDraft.trim().length > 0 || composerAttachments.length > 0
  ), [composerAttachments.length, composerDraft]);
  const isStreaming = connectionState === "connecting" || Boolean(streamingMessage);

  const handleFileChange = async (event: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files || []);
    for (const file of files) {
      try {
        const attachment = await fileToComposerAttachment(file);
        addComposerAttachment(attachment);
      } catch (error) {
        console.warn("Failed to add attachment:", error);
      }
    }
    event.target.value = "";
  };

  const handlePaste = async (event: ClipboardEvent<HTMLInputElement>) => {
    const items = Array.from(event.clipboardData?.items || []);
    for (const item of items) {
      const file = item.getAsFile();
      if (!file) {
        continue;
      }
      try {
        const attachment = await fileToComposerAttachment(file);
        addComposerAttachment(attachment);
      } catch (error) {
        console.warn("Failed to add pasted attachment:", error);
      }
    }
  };

  const handleDrop = async (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    const files = Array.from(event.dataTransfer.files || []);
    for (const file of files) {
      try {
        const attachment = await fileToComposerAttachment(file);
        addComposerAttachment(attachment);
      } catch (error) {
        console.warn("Failed to add dropped attachment:", error);
      }
    }
  };

  const handleSend = async () => {
    if (hasUnresolvedAttachments) {
      return;
    }
    const action = getComposerAction({
      hasContent,
      isStreaming,
    });
    if (action === "noop") {
      return;
    }
    if (action === "interrupt") {
      interrupt();
      return;
    }

    const capturedMedia = await captureAllMedia();
    for (const image of capturedMedia) {
      const attachment = await fileToComposerAttachment(
        await dataUrlToFile(image.data, `${image.source}-capture.jpg`),
      );
      addComposerAttachment(attachment);
    }

    await sendComposerMessage();
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (isComposing) {
      return;
    }

    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void handleSend();
    }
  };

  const handleCameraClick = async () => {
    const file = await captureCameraStill();
    if (file) {
      addComposerAttachment(await fileToComposerAttachment(file));
    }
  };

  const handleScreenshotClick = async () => {
    if (onScreenshotClick) {
      onScreenshotClick();
      return;
    }

    const dataUrl = await window.api?.capturePrimaryScreen?.();
    if (dataUrl) {
      await addCaptureDataUrl(dataUrl, "screenshot.jpg");
    }
  };

  return (
    <Stack
      gap="3"
      onDragOver={(event) => event.preventDefault()}
      onDrop={handleDrop}
      pt={isMobileSized ? "2" : undefined}
      pb={isMobileSized ? "calc(env(safe-area-inset-bottom, 0px) + 4px)" : undefined}
    >
      {composerAttachments.length > 0 && (
        <Flex gap="2" wrap="wrap">
          {composerAttachments.map((attachment) => (
            <AttachmentChip
              key={attachment.id}
              attachment={attachment}
              onRemove={() => removeComposerAttachment(attachment.id)}
            />
          ))}
        </Flex>
      )}

      <HStack align="center" gap="2">
        {showPlusButton && (
          <IconButton
            aria-label={t("composer.openActions")}
            onClick={onPlusClick}
            {...lunariaIconButtonStyles}
            h={controlSize}
            w={controlSize}
            minW={controlSize}
          >
            <LuPlus />
          </IconButton>
        )}

        <Box
          flex="1"
          borderRadius={compact ? "18px" : "20px"}
          bg={lunariaColors.cardStrong}
          border="1px solid"
          borderColor={lunariaColors.border}
          h={controlSize}
          px={isMobileSized ? "3.5" : "4"}
          display="flex"
          alignItems="center"
          transition="border-color 0.18s ease, box-shadow 0.18s ease"
          _focusWithin={{
            borderColor: lunariaColors.primaryStrong,
            boxShadow: "0 0 0 2px rgba(220, 141, 121, 0.12)",
          }}
        >
          <Input
            value={composerDraft}
            onChange={(event) => setComposerDraft(event.target.value)}
            onKeyDown={handleKeyDown}
            onPaste={handlePaste}
            onCompositionStart={() => setIsComposing(true)}
            onCompositionEnd={() => setIsComposing(false)}
            placeholder={t("composer.placeholder")}
            bg="transparent"
            fontSize={isMobileSized ? "14px" : undefined}
            border="none"
            outline="none"
            px="0"
            h="100%"
            minH={isMobileSized ? "40px" : "unset"}
            boxShadow="none"
            _focus={{ boxShadow: "none", outline: "none" }}
            _focusVisible={{ boxShadow: "none", outline: "none" }}
          />
        </Box>

        {showWindowTools && (
          <HStack gap="1">
            <IconButton
              aria-label={t("composer.uploadAttachment")}
              onClick={() => fileInputRef.current?.click()}
              {...lunariaIconButtonStyles}
              h={controlSize}
              w={controlSize}
              minW={controlSize}
            >
              <LuImagePlus />
            </IconButton>
            <IconButton
              aria-label={t("composer.cameraSnapshot")}
              onClick={() => void handleCameraClick()}
              {...lunariaIconButtonStyles}
              h={controlSize}
              w={controlSize}
              minW={controlSize}
            >
              <LuCamera />
            </IconButton>
            <Button
              onClick={() => void handleScreenshotClick()}
              {...lunariaSecondaryButtonStyles}
              h={controlSize}
              minW={compact ? "66px" : "72px"}
            >
              {t("composer.screenshot")}
            </Button>
          </HStack>
        )}

        <IconButton
          aria-label={isStreaming ? t("common.interrupt") : t("common.send")}
          onClick={() => void handleSend()}
          disabled={!isStreaming && hasUnresolvedAttachments}
          {...(isStreaming ? lunariaSecondaryButtonStyles : lunariaPrimaryButtonStyles)}
          h={controlSize}
          w={controlSize}
          minW={controlSize}
        >
          {isStreaming ? <LuX /> : <LuSend />}
        </IconButton>
      </HStack>

      <input
        ref={fileInputRef}
        type="file"
        accept="image/*,audio/*,video/*,.pdf,.txt,.md,.json,.zip"
        multiple
        hidden
        onChange={handleFileChange}
      />
    </Stack>
  );
}
