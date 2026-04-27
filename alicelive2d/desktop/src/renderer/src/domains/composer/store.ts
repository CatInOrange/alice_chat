import { create } from "zustand";
import { ChatAttachmentInput } from "@/platform/backend/openclaw-api";
import {
  createFileComposerAttachment,
  resolveComposerAttachmentChatInput,
} from "@/runtime/composer-attachment-utils.ts";
import type { ComposerAttachment } from "@/domains/types";
import { AttachmentKind } from "@/domains/types";

interface ComposerState {
  composerDraft: string;
  composerAttachments: ComposerAttachment[];
  setComposerDraft: (value: string) => void;
  addComposerAttachment: (attachment: ComposerAttachment) => void;
  updateComposerAttachment: (attachmentId: string, value: Partial<ComposerAttachment>) => void;
  removeComposerAttachment: (attachmentId: string) => void;
  clearComposerAttachments: () => void;
  clearComposer: () => void;
}

export function createComposerAttachmentId(): string {
  return `att_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

function detectAttachmentKind(mimeType: string): AttachmentKind {
  if (mimeType.startsWith("image/")) {
    return "image";
  }
  if (mimeType.startsWith("audio/")) {
    return "audio";
  }
  if (mimeType.startsWith("video/")) {
    return "video";
  }
  return "file";
}

export async function fileToComposerAttachment(file: File): Promise<ComposerAttachment> {
  const kind = detectAttachmentKind(file.type || "application/octet-stream");
  const attachment = createFileComposerAttachment({
    file,
    id: createComposerAttachmentId(),
    previewUrl: kind === "image" ? URL.createObjectURL(file) : "",
  });
  return {
    ...attachment,
    id: attachment.id || createComposerAttachmentId(),
    kind,
    source: "base64",
  };
}

export function dataUrlToComposerAttachment(
  dataUrl: string,
  filename = "capture.png",
): ComposerAttachment {
  const match = String(dataUrl || "").match(/^data:([^;]+);base64,(.+)$/);
  const mimeType = match?.[1] || "image/png";
  return {
    id: createComposerAttachmentId(),
    kind: detectAttachmentKind(mimeType),
    filename,
    mimeType,
    previewUrl: dataUrl,
    source: "base64",
    data: match?.[2] || "",
  };
}

export async function dataUrlToFile(
  dataUrl: string,
  filename = "attachment",
): Promise<File> {
  const response = await fetch(dataUrl);
  const blob = await response.blob();
  return new File([blob], filename, {
    type: blob.type || "application/octet-stream",
  });
}

async function readFileAsDataUrl(file: File): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

export async function attachmentToChatInput(
  attachment: ComposerAttachment,
): Promise<ChatAttachmentInput> {
  if (attachment.data) {
    return resolveComposerAttachmentChatInput({
      attachment,
      resolvedDataUrl: "",
    });
  }

  if (attachment.file) {
    const resolvedDataUrl = await readFileAsDataUrl(attachment.file);
    return resolveComposerAttachmentChatInput({
      attachment,
      resolvedDataUrl,
    });
  }

  if (attachment.tempFileUrl) {
    const resolvedDataUrl = await window.api?.readTempScreenshotFile?.(attachment.tempFileUrl);
    if (!resolvedDataUrl) {
      throw new Error(`failed to read temp attachment file: ${attachment.filename}`);
    }
    return resolveComposerAttachmentChatInput({
      attachment,
      resolvedDataUrl,
    });
  }

  return resolveComposerAttachmentChatInput({
    attachment: {
      ...attachment,
      data: "",
    },
    resolvedDataUrl: attachment.previewUrl,
  });
}

function releaseComposerAttachmentResources(attachments: ComposerAttachment | ComposerAttachment[] | null | undefined): void {
  for (const attachment of Array.isArray(attachments) ? attachments : attachments ? [attachments] : []) {
    if (attachment.cleanupToken) {
      void window.api?.deleteTempScreenshotFile?.(attachment.cleanupToken);
    }
    if (attachment.previewUrl?.startsWith("blob:")) {
      URL.revokeObjectURL(attachment.previewUrl);
    }
  }
}

function updateComposerAttachment(
  existing: ComposerAttachment[],
  attachmentId: string,
  value: Partial<ComposerAttachment>,
): ComposerAttachment[] {
  const index = existing.findIndex((item) => item.id === attachmentId);
  if (index === -1) {
    return existing;
  }

  const clone = [...existing];
  clone[index] = {
    ...clone[index],
    ...value,
  };
  return clone;
}

export const useComposerStore = create<ComposerState>((set, get) => ({
  composerDraft: "",
  composerAttachments: [],
  setComposerDraft: (value) => set({ composerDraft: value }),
  addComposerAttachment: (attachment) => set((state) => ({
    composerAttachments: [...state.composerAttachments, attachment],
  })),
  updateComposerAttachment: (attachmentId, value) => set((state) => ({
    composerAttachments: updateComposerAttachment(state.composerAttachments, attachmentId, value),
  })),
  removeComposerAttachment: (attachmentId) => {
    const removedAttachment = get().composerAttachments.find((item) => item.id === attachmentId);
    releaseComposerAttachmentResources(removedAttachment);
    set((state) => ({
      composerAttachments: state.composerAttachments.filter((item) => item.id !== attachmentId),
    }));
  },
  clearComposerAttachments: () => {
    releaseComposerAttachmentResources(get().composerAttachments);
    set({ composerAttachments: [] });
  },
  clearComposer: () => {
    releaseComposerAttachmentResources(get().composerAttachments);
    set({ composerDraft: "", composerAttachments: [] });
  },
}));
