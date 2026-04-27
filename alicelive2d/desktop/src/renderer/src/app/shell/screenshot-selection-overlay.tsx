import { Box, Button, HStack, Stack, Text } from "@chakra-ui/react";
import { useCallback, useEffect, useRef, useState } from "react";
import type { MouseEvent } from "react";
import { useTranslation } from "react-i18next";
import {
  createFullScreenSelection,
  hasMeaningfulSelection,
  clampSelectionRect,
  selectionCoversBounds,
  toPositiveRect,
} from "@/runtime/screenshot-utils.ts";
import {
  lunariaColors,
  lunariaEyebrowStyles,
  lunariaPanelStyles,
  lunariaPrimaryButtonStyles,
  lunariaSecondaryButtonStyles,
} from "@/theme/lunaria-theme";

interface DisplayRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface SelectionRect extends DisplayRect {}

interface ResolvedCapturePayload {
  fileUrl: string;
  cleanupToken: string;
  mimeType: string;
}

function waitForNextPaint(): Promise<void> {
  return new Promise((resolve) => {
    window.requestAnimationFrame(() => resolve());
  });
}

async function waitForWindowRestore(): Promise<void> {
  await waitForNextPaint();
  await waitForNextPaint();
}

function getRelativePoint(event: MouseEvent<HTMLElement>, rect: DOMRect) {
  return {
    x: event.clientX - rect.left,
    y: event.clientY - rect.top,
  };
}

async function cropToTempFile(
  fileUrl: string,
  displayRect: DisplayRect,
  selection: SelectionRect,
): Promise<ResolvedCapturePayload> {
  const nextFile = await window.api?.cropTempScreenshotFile?.({
    fileUrl,
    selection,
    displaySize: {
      width: displayRect.width,
      height: displayRect.height,
    },
  });

  if (!nextFile) {
    throw new Error("failed to crop screenshot");
  }

  return nextFile;
}

function replaceFilenameExtension(filename: string, replacement: string): string {
  return filename.replace(/\.(png|jpg|jpeg)$/i, replacement);
}

export default function ScreenshotSelectionOverlay({
  fileUrl,
  cleanupToken,
  filename,
  onCancel,
  onCreateCapture,
  onResolveCapture,
  onFailCapture,
}: {
  fileUrl: string;
  cleanupToken: string;
  filename: string;
  onCancel: () => void;
  onCreateCapture: (nextFilename: string) => Promise<string> | string;
  onResolveCapture: (attachmentId: string, payload: ResolvedCapturePayload, nextFilename: string) => Promise<void> | void;
  onFailCapture: (attachmentId: string) => Promise<void> | void;
}): JSX.Element {
  const { t } = useTranslation();
  const imageRef = useRef<HTMLImageElement | null>(null);
  const dragStartRef = useRef<{ x: number; y: number } | null>(null);
  const mountedRef = useRef(true);
  const sessionFinishPromiseRef = useRef<Promise<void> | null>(null);
  const sessionFinishHandledRef = useRef(false);
  const cleanupTokenRef = useRef(cleanupToken);
  const processingSelectionRef = useRef(false);
  const [selection, setSelection] = useState<SelectionRect | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    cleanupTokenRef.current = cleanupToken;
  }, [cleanupToken]);

  const releaseSourceFile = useCallback(() => {
    const token = cleanupTokenRef.current;
    if (!token) {
      return;
    }
    cleanupTokenRef.current = "";
    void window.api?.deleteTempScreenshotFile?.(token);
  }, []);

  const closeSelectionSession = useCallback(async () => {
    if (!sessionFinishPromiseRef.current) {
      sessionFinishHandledRef.current = true;
      onCancel();
      sessionFinishPromiseRef.current = (async () => {
        await waitForNextPaint();
        await window.api?.finishScreenshotSelection?.();
        await waitForNextPaint();
      })();
    }

    await sessionFinishPromiseRef.current;
  }, [onCancel]);

  useEffect(() => {
    mountedRef.current = true;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        void closeSelectionSession();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      mountedRef.current = false;
      if (!processingSelectionRef.current) {
        releaseSourceFile();
      }
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [closeSelectionSession, releaseSourceFile]);

  useEffect(() => {
    void window.api?.showScreenshotSelection?.();
    return () => {
      if (!sessionFinishHandledRef.current) {
        void window.api?.finishScreenshotSelection?.();
      }
    };
  }, []);

  const handleMouseDown = (event: MouseEvent<HTMLImageElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    dragStartRef.current = getRelativePoint(event, rect);
    setSelection(null);
  };

  const handleMouseMove = (event: MouseEvent<HTMLImageElement>) => {
    if (!dragStartRef.current) {
      return;
    }
    const rect = event.currentTarget.getBoundingClientRect();
    const currentPoint = getRelativePoint(event, rect);
    setSelection(clampSelectionRect(
      toPositiveRect(dragStartRef.current, currentPoint),
      { width: rect.width, height: rect.height },
    ));
  };

  const handleMouseUp = (event: MouseEvent<HTMLImageElement>) => {
    if (!dragStartRef.current) {
      return;
    }
    const rect = event.currentTarget.getBoundingClientRect();
    const currentPoint = getRelativePoint(event, rect);
    const nextSelection = clampSelectionRect(
      toPositiveRect(dragStartRef.current, currentPoint),
      { width: rect.width, height: rect.height },
    );
    dragStartRef.current = null;
    setSelection(hasMeaningfulSelection(nextSelection) ? nextSelection : null);
  };

  const commitSelection = useCallback(async (
    nextSelection: SelectionRect,
    nextFilename: string,
  ) => {
    const node = imageRef.current;
    if (!node) {
      return;
    }

    const displayRect = {
      x: 0,
      y: 0,
      width: node.clientWidth,
      height: node.clientHeight,
    };
    processingSelectionRef.current = true;
    const isWholeScreen = selectionCoversBounds(nextSelection, displayRect);
    const sourceExtension = fileUrl.toLowerCase().endsWith(".png") ? ".png" : ".jpg";
    const finalName = isWholeScreen
      ? replaceFilenameExtension(nextFilename, sourceExtension)
      : replaceFilenameExtension(nextFilename, ".png");
    const attachmentId = await onCreateCapture(finalName);
    await closeSelectionSession();
    await waitForWindowRestore();
    await new Promise((r) => setTimeout(r, 0));

    if (isWholeScreen) {
      try {
        await onResolveCapture(attachmentId, {
          cleanupToken,
          fileUrl,
          mimeType: sourceExtension === ".png" ? "image/png" : "image/jpeg",
        }, finalName);
        cleanupTokenRef.current = "";
      } catch (error) {
        console.warn("Failed to resolve full-screen screenshot preview:", error);
        await onFailCapture(attachmentId);
      } finally {
        processingSelectionRef.current = false;
        releaseSourceFile();
      }
      return;
    }

    void (async () => {
      let croppedFile: ResolvedCapturePayload | null = null;
      try {
        croppedFile = await cropToTempFile(fileUrl, displayRect, nextSelection);
        await onResolveCapture(attachmentId, croppedFile, finalName);
      } catch (error) {
        if (croppedFile?.cleanupToken) {
          void window.api?.deleteTempScreenshotFile?.(croppedFile.cleanupToken);
        }
        console.warn("Failed to resolve screenshot preview:", error);
        await onFailCapture(attachmentId);
      } finally {
        processingSelectionRef.current = false;
        releaseSourceFile();
      }
    })();
  }, [closeSelectionSession, fileUrl, onCreateCapture, onFailCapture, onResolveCapture, releaseSourceFile]);

  const handleAddSelection = async () => {
    if (!selection) {
      return;
    }
    setBusy(true);
    try {
      await commitSelection(selection, replaceFilenameExtension(filename, "-crop.jpg"));
    } finally {
      if (mountedRef.current) {
        setBusy(false);
      }
    }
  };

  const handleAddWholeScreen = async () => {
    const node = imageRef.current;
    if (!node) {
      return;
    }

    setBusy(true);
    try {
      await commitSelection(
        createFullScreenSelection({ width: node.clientWidth, height: node.clientHeight }),
        filename,
      );
    } finally {
      if (mountedRef.current) {
        setBusy(false);
      }
    }
  };

  return (
    <Box
      position="fixed"
      inset="0"
      zIndex="2000"
      bg="black"
      cursor="crosshair"
    >
      <Stack position="absolute" top="5" right="5" gap="3" align="end" zIndex="2" {...lunariaPanelStyles} p="4">
        <Box textAlign="right">
          <Text {...lunariaEyebrowStyles}>{t("screenshotOverlay.title")}</Text>
          <Text color={lunariaColors.text} fontSize="sm" mt="1.5">
            {t("screenshotOverlay.description")}
          </Text>
        </Box>
        <HStack gap="2">
          <Button size="sm" {...lunariaSecondaryButtonStyles} disabled={busy} onClick={() => void closeSelectionSession()}>{t("common.cancel")}</Button>
          <Button size="sm" {...lunariaSecondaryButtonStyles} disabled={busy} onClick={() => void handleAddWholeScreen()}>
            {t("screenshotOverlay.addFullScreen")}
          </Button>
          <Button size="sm" {...lunariaPrimaryButtonStyles} disabled={!selection || busy} onClick={() => void handleAddSelection()}>
            {t("screenshotOverlay.addSelection")}
          </Button>
        </HStack>
      </Stack>

      <Box
        position="absolute"
        inset="0"
      >
        <img
          ref={imageRef}
          src={fileUrl}
          alt={t("screenshotOverlay.imageAlt")}
          onMouseDown={handleMouseDown}
          onMouseMove={handleMouseMove}
          onMouseUp={handleMouseUp}
          onMouseLeave={() => {
            dragStartRef.current = null;
          }}
          draggable={false}
          style={{
            width: "100vw",
            height: "100vh",
            display: "block",
            objectFit: "fill",
            userSelect: "none",
            cursor: "crosshair",
          }}
        />

        {selection ? (
          <Box
            position="absolute"
            left={`${selection.x}px`}
            top={`${selection.y}px`}
            width={`${selection.width}px`}
            height={`${selection.height}px`}
            border="2px solid"
            borderColor={lunariaColors.primaryStrong}
            boxShadow="0 0 0 9999px rgba(0, 0, 0, 0.45)"
            borderRadius="12px"
            pointerEvents="none"
          />
        ) : (
          <Box
            position="absolute"
            inset="0"
            boxShadow="inset 0 0 0 9999px rgba(0, 0, 0, 0.18)"
            pointerEvents="none"
          />
        )}
      </Box>
    </Box>
  );
}
