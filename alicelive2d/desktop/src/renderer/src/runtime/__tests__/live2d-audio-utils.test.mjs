import test from "node:test";
import assert from "node:assert/strict";

import { getLipSyncPlaybackMode } from "../live2d-audio-utils.ts";

test("getLipSyncPlaybackMode prefers wav handler for wav mime types", () => {
  assert.equal(getLipSyncPlaybackMode({
    audioMimeType: "audio/wav",
    audioSource: "blob:http://localhost/demo",
  }), "wav-handler");
});

test("getLipSyncPlaybackMode prefers wav handler for wav urls and data urls", () => {
  assert.equal(getLipSyncPlaybackMode({
    audioSource: "http://127.0.0.1/reply.wav",
  }), "wav-handler");

  assert.equal(getLipSyncPlaybackMode({
    audioSource: "data:audio/x-wav;base64,AAAA",
  }), "wav-handler");
});

test("getLipSyncPlaybackMode falls back to realtime analysis for non-wav audio", () => {
  assert.equal(getLipSyncPlaybackMode({
    audioMimeType: "audio/mpeg",
    audioSource: "http://127.0.0.1/reply.mp3",
  }), "realtime");
});

test("getLipSyncPlaybackMode returns none for empty sources", () => {
  assert.equal(getLipSyncPlaybackMode({
    audioMimeType: "",
    audioSource: "",
  }), "none");
});
