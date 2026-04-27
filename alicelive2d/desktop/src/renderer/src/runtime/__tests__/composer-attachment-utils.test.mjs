import test from "node:test";
import assert from "node:assert/strict";

import {
  createFileComposerAttachment,
  createTempFileComposerAttachment,
  resolveComposerAttachmentChatInput,
} from "../composer-attachment-utils.ts";

test("createTempFileComposerAttachment keeps screenshot previews as file URLs until send time", () => {
  assert.deepEqual(
    createTempFileComposerAttachment({
      cleanupToken: "shot_123.png",
      fileUrl: "file:///tmp/shot_123.png",
      filename: "screen-capture.png",
      id: "att_123",
      kind: "image",
      mimeType: "image/png",
    }),
    {
      cleanupToken: "shot_123.png",
      data: "",
      filename: "screen-capture.png",
      id: "att_123",
      kind: "image",
      mimeType: "image/png",
      previewUrl: "file:///tmp/shot_123.png",
      source: "base64",
      tempFileUrl: "file:///tmp/shot_123.png",
    },
  );
});

test("resolveComposerAttachmentChatInput defers temp screenshot base64 conversion until file data is read", () => {
  assert.deepEqual(
    resolveComposerAttachmentChatInput({
      attachment: createTempFileComposerAttachment({
        cleanupToken: "shot_456.jpg",
        fileUrl: "file:///tmp/shot_456.jpg",
        filename: "screen-capture.jpg",
        id: "att_456",
        kind: "image",
        mimeType: "image/jpeg",
      }),
      resolvedDataUrl: "data:image/jpeg;base64,abc123",
    }),
    {
      data: "abc123",
      mediaType: "image/jpeg",
      type: "base64",
    },
  );
});

test("resolveComposerAttachmentChatInput preserves existing base64 attachments", () => {
  assert.deepEqual(
    resolveComposerAttachmentChatInput({
      attachment: {
        data: "xyz789",
        filename: "camera.jpg",
        id: "att_camera",
        kind: "image",
        mimeType: "image/jpeg",
        previewUrl: "data:image/jpeg;base64,xyz789",
        source: "base64",
      },
    }),
    {
      data: "xyz789",
      mediaType: "image/jpeg",
      type: "base64",
    },
  );
});

test("createFileComposerAttachment keeps uploaded images as lightweight previews until send time", () => {
  const file = new File(["preview"], "upload.jpg", { type: "image/jpeg" });

  assert.deepEqual(
    createFileComposerAttachment({
      file,
      id: "att_upload",
      previewUrl: "blob:upload-preview",
    }),
    {
      data: "",
      file,
      filename: "upload.jpg",
      id: "att_upload",
      kind: "image",
      mimeType: "image/jpeg",
      previewUrl: "blob:upload-preview",
      source: "base64",
    },
  );
});
