import {
  Box,
  Flex,
  Icon,
  Image,
  Link,
  Stack,
  Text,
} from "@chakra-ui/react";
import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { FaPaperclip } from "react-icons/fa";
import type { LunariaMessage } from "@/platform/backend/openclaw-api";
import { selectCurrentSessionMessages, useAppStore } from "@/domains/renderer-store";
import type { StreamingMessage } from "@/domains/types";
import {
  getLunariaScrollbarStyles,
  shouldAutoScrollMessageList,
} from "@/runtime/chat-shell-utils.ts";
import { resolveAutomationNoteKind } from "@/runtime/chat-surface-utils.ts";
import {
  formatChatMessageMeta,
  formatStreamingMessageMeta,
} from "@/runtime/chat-time-utils.ts";
import {
  lunariaCardStyles,
  lunariaColors,
  getLunariaIntentStyles,
} from "@/theme/lunaria-theme";

const lunariaScrollbarStyles = getLunariaScrollbarStyles();
const hiddenScrollbarStyles = getLunariaScrollbarStyles({ hidden: true });

function attachmentHref(url: string, backendUrl: string): string {
  if (!url) {
    return "";
  }

  return /^https?:\/\//i.test(url) || url.startsWith("data:")
    ? url
    : `${backendUrl.replace(/\/+$/, "")}${url.startsWith("/") ? "" : "/"}${url}`;
}

function MessageAttachments({
  attachments,
  backendUrl,
}: {
  attachments: Array<{
    kind?: string;
    mimeType?: string;
    url?: string;
    data?: string;
    filename?: string;
  }>;
  backendUrl: string;
}) {
  const { t } = useTranslation();

  if (!attachments.length) {
    return null;
  }

  return (
    <Stack gap="2.5" mt="3">
      {attachments.map((attachment, index) => {
        const href = attachment.url
          ? attachmentHref(attachment.url, backendUrl)
          : attachment.data
            ? `data:${attachment.mimeType || "application/octet-stream"};base64,${attachment.data}`
            : "";

        if (!href) {
          return null;
        }

        const mimeType = String(attachment.mimeType || "").toLowerCase();
        const kind = String(attachment.kind || "").toLowerCase();
        if (mimeType.startsWith("image/") || kind === "image") {
          return (
            <Image
              key={`${attachment.filename || "attachment"}_${index}`}
              src={href}
              alt={attachment.filename || t("chat.attachment")}
              width="100%"
              maxH="220px"
              objectFit="cover"
              borderRadius="18px"
              border="1px solid"
              borderColor={lunariaColors.border}
            />
          );
        }

        if (mimeType.startsWith("audio/") || kind === "audio") {
          return <audio key={`${attachment.filename || "attachment"}_${index}`} src={href} controls style={{ width: "100%" }} />;
        }

        if (mimeType.startsWith("video/") || kind === "video") {
          return <video key={`${attachment.filename || "attachment"}_${index}`} src={href} controls style={{ width: "100%", borderRadius: 18 }} />;
        }

        return (
          <Flex
            key={`${attachment.filename || "attachment"}_${index}`}
            align="center"
            gap="2"
            {...lunariaCardStyles}
            borderRadius="14px"
            px="3"
            py="2"
          >
            <Icon as={FaPaperclip} color={lunariaColors.textSubtle} />
            <Link href={href} target="_blank" rel="noreferrer" color={lunariaColors.primaryStrong}>
              {attachment.filename || t("shell.downloadAttachment")}
            </Link>
          </Flex>
        );
      })}
    </Stack>
  );
}

export interface MessageListProps {
  messages: LunariaMessage[];
  backendUrl: string;
  assistantName?: string;
  userName?: string;
  compact?: boolean;
  hideScrollbar?: boolean;
  variant?: "window" | "pet";
  currentSessionId?: string | null;
  streamingMessage?: StreamingMessage | null;
  autoScroll?: boolean;
  scrollable?: boolean;
  emptyState?: {
    title?: string;
    hint?: string;
  };
}

export function MessageList({
  messages,
  backendUrl,
  assistantName,
  userName,
  compact = false,
  hideScrollbar = false,
  variant = "window",
  currentSessionId = null,
  streamingMessage = null,
  autoScroll = false,
  scrollable = true,
  emptyState,
}: MessageListProps) {
  const { t } = useTranslation();
  const listRef = useRef<HTMLDivElement | null>(null);
  const previousSnapshotRef = useRef({
    sessionId: null as string | null,
    messageCount: 0,
    streamingText: "",
  });

  const activeStreamingMessage = currentSessionId && streamingMessage?.sessionId === currentSessionId
    ? streamingMessage
    : null;
  const activeStreamingText = activeStreamingMessage?.text || "";
  const hasStreaming = Boolean(activeStreamingText && currentSessionId);

  useEffect(() => {
    if (!autoScroll) {
      return;
    }

    const nextSnapshot = {
      sessionId: currentSessionId,
      messageCount: messages.length,
      streamingText: activeStreamingText,
    };

    if (shouldAutoScrollMessageList({
      previousSessionId: previousSnapshotRef.current.sessionId,
      nextSessionId: nextSnapshot.sessionId,
      previousMessageCount: previousSnapshotRef.current.messageCount,
      nextMessageCount: nextSnapshot.messageCount,
      previousStreamingText: previousSnapshotRef.current.streamingText,
      nextStreamingText: nextSnapshot.streamingText,
    })) {
      const listElement = listRef.current;
      if (listElement) {
        listElement.scrollTop = listElement.scrollHeight;
      }
    }

    previousSnapshotRef.current = nextSnapshot;
  }, [activeStreamingText, autoScroll, currentSessionId, messages.length]);

  if (!messages.length && !hasStreaming) {
    if (emptyState?.title || emptyState?.hint) {
      return (
        <Flex
          ref={listRef}
          flex={scrollable ? "1" : undefined}
          minH={scrollable ? "0" : undefined}
          align="center"
          justify="center"
          px="5"
          css={scrollable ? (hideScrollbar ? hiddenScrollbarStyles : lunariaScrollbarStyles) : undefined}
        >
          <Stack gap="2" textAlign="center" align="center">
            {emptyState.title ? (
              <Text fontSize="xs" fontWeight="700" textTransform="uppercase" letterSpacing="0.18em" color={lunariaColors.textSubtle}>
                {emptyState.title}
              </Text>
            ) : null}
            {emptyState.hint ? (
              <Text fontSize="sm" color={lunariaColors.textMuted}>
                {emptyState.hint}
              </Text>
            ) : null}
          </Stack>
        </Flex>
      );
    }

    return (
      <Flex align="center" justify="center" h="100%" color={lunariaColors.textMuted}>
        {t("chat.empty")}
      </Flex>
    );
  }

  return (
    <Stack
      ref={listRef}
      gap={variant === "window" ? "4" : (compact ? 2 : 3)}
      flex={scrollable ? "1" : undefined}
      overflowY={scrollable ? "auto" : undefined}
      pr={scrollable ? "1" : undefined}
      minH={scrollable ? "0" : undefined}
      css={scrollable ? (hideScrollbar ? hiddenScrollbarStyles : lunariaScrollbarStyles) : undefined}
    >
      {messages.map((message) => {
        const isAssistant = message.role === "assistant";
        const isSystem = message.role === "system";
        const automationKind = resolveAutomationNoteKind(message);
        const bubbleTone = isSystem
          ? getLunariaIntentStyles("neutral")
            : isAssistant
              ? {
                // 女生 Live2D 气泡 - 温柔的粉紫色
                bg: "#f8bbd0",
                color: "#880e4f",
                borderColor: "#ec407a",
              }
              : {
                // 姐夫/男生气泡 - 清新的青蓝色
                bg: "#b2ebf2",
                color: "#006064",
                borderColor: "#00bcd4",
              };

        if (automationKind || isSystem) {
          const noteText = automationKind
            ? t(
              automationKind === "screenshot"
                ? "shell.automationTriggeredScreenshot"
                : "shell.automationTriggeredProactive",
            )
            : message.text;

          return (
            <Flex key={message.id} justify="center">
              <Box
                px="3"
                py="1.5"
                borderRadius="999px"
                bg="rgba(148, 163, 184, 0.14)"
                border="1px solid"
                borderColor="rgba(148, 163, 184, 0.26)"
              >
                <Text fontSize="xs" color={lunariaColors.textMuted}>
                  {noteText}
                </Text>
              </Box>
            </Flex>
          );
        }

        return (
          <Box
            key={message.id}
            alignSelf={isAssistant ? "flex-start" : "flex-end"}
            maxW={compact ? "94%" : "88%"}
            bg={bubbleTone.bg}
            border="1px solid"
            borderColor={bubbleTone.borderColor}
            borderRadius="22px"
            px="4"
            py="3.5"
            color={bubbleTone.color}
            boxShadow="0 10px 24px rgba(121, 93, 77, 0.08)"
          >
            <Text fontSize="11px" color={lunariaColors.textSubtle} mb="1.5" fontWeight="600">
              {formatChatMessageMeta({
                speaker: isAssistant
                  ? ((message.source === "automation" ? "" : message.meta) || assistantName || t("shell.speakerAssistant"))
                  : (userName || t("shell.speakerYou")),
                timestamp: message.createdAt,
              })}
            </Text>
            {message.text ? (
              <Text whiteSpace="pre-wrap" fontSize={compact ? "sm" : "md"} lineHeight="1.75">
                {message.text}
              </Text>
            ) : null}
            <MessageAttachments attachments={message.attachments || []} backendUrl={backendUrl} />
          </Box>
        );
      })}

      {hasStreaming ? (
        <Box
          alignSelf="flex-start"
          maxW={compact ? "94%" : "88%"}
          bg={lunariaColors.cardStrong}
          border="1px solid"
          borderColor={lunariaColors.border}
          borderRadius="22px"
          px="4"
          py="3.5"
          color={lunariaColors.text}
          boxShadow="0 10px 24px rgba(121, 93, 77, 0.08)"
        >
          <Text fontSize="11px" color={lunariaColors.textSubtle} mb="1.5" fontWeight="600">
            {formatStreamingMessageMeta({
              speaker: assistantName || t("shell.speakerAssistant"),
              timestamp: activeStreamingMessage?.createdAt,
            })}
          </Text>
          <Text whiteSpace="pre-wrap" fontSize={compact ? "sm" : "md"} lineHeight="1.75">
            {activeStreamingText || "..."}
          </Text>
        </Box>
      ) : null}
    </Stack>
  );
}

export function CurrentSessionMessageList(
  props: Omit<
    MessageListProps,
    "messages" | "backendUrl" | "currentSessionId" | "streamingMessage" | "autoScroll"
  >,
) {
  const backendUrl = useAppStore((state) => state.backendUrl);
  const currentSessionId = useAppStore((state) => state.currentSessionId);
  const messages = useAppStore(selectCurrentSessionMessages);
  const streamingMessage = useAppStore((state) => state.streamingMessage);

  return (
    <MessageList
      {...props}
      messages={messages}
      backendUrl={backendUrl}
      currentSessionId={currentSessionId}
      streamingMessage={streamingMessage}
      autoScroll
    />
  );
}
