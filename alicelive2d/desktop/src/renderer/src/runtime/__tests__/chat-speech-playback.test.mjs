import test from "node:test";
import assert from "node:assert/strict";

import { createSpeechPlaybackController } from "../chat-speech-playback.ts";

function createFakeAudioFactory() {
  const created = [];

  const factory = (src) => {
    const listeners = new Map();
    const audio = {
      src,
      crossOrigin: "",
      ended: false,
      addEventListener(type, handler) {
        listeners.set(type, handler);
      },
      pause() {},
      async play() {
        queueMicrotask(() => {
          audio.ended = true;
          listeners.get("ended")?.();
        });
      },
    };
    created.push({ audio, listeners });
    return audio;
  };

  return {
    created,
    factory,
  };
}

test("createSpeechPlaybackController applies directives and plays relative audio urls through the backend base url", async () => {
  const directives = [];
  const stopCalls = [];
  const wavStarts = [];
  const managerCalls = {
    set: [],
    clear: [],
  };
  const fakeAudio = createFakeAudioFactory();
  const model = {
    _externalLipSyncValue: null,
    _wavFileHandler: {
      start(source) {
        wavStarts.push(source);
      },
    },
  };

  const controller = createSpeechPlaybackController({
    getContext: () => ({
      normalizedBackendUrl: "http://127.0.0.1:8000",
      ttsEnabled: false,
      ttsProvider: "edge",
      ttsOverrides: {},
    }),
    requestTts: async () => {
      throw new Error("requestTts should not be called when audioUrl is already provided");
    },
    applyStageDirectives: (items) => directives.push(items),
    stopCurrentAudio: () => {
      stopCalls.push(true);
    },
    createAudio: fakeAudio.factory,
    getActiveLive2DModel: () => model,
    buildBackendUrl: (baseUrl, targetUrl) => `${baseUrl}${targetUrl}`,
    audioManager: {
      setCurrentAudio: (audio, activeModel, cleanup) => {
        managerCalls.set.push({ audio, activeModel, cleanup });
      },
      clearCurrentAudio: (audio) => {
        managerCalls.clear.push(audio);
      },
    },
    getLipSyncPlaybackMode: ({ audioMimeType }) => (
      String(audioMimeType || "").includes("wav") ? "wav-handler" : "none"
    ),
    createRealtimeLipSyncCleanup: () => null,
  });

  controller.enqueue({
    audioUrl: "/audio/reply.wav",
    audioMimeType: "audio/wav",
    directives: [{ type: "motion", group: "Idle", index: 0 }],
  });

  await controller.waitForIdle();

  assert.deepEqual(directives, [[{ type: "motion", group: "Idle", index: 0 }]]);
  assert.equal(stopCalls.length, 1);
  assert.equal(fakeAudio.created.length, 1);
  assert.equal(fakeAudio.created[0].audio.src, "http://127.0.0.1:8000/audio/reply.wav");
  assert.equal(fakeAudio.created[0].audio.crossOrigin, "anonymous");
  assert.equal(managerCalls.set.length, 1);
  assert.equal(managerCalls.set[0].activeModel, model);
  assert.deepEqual(wavStarts, ["http://127.0.0.1:8000/audio/reply.wav"]);
  assert.deepEqual(managerCalls.clear, [fakeAudio.created[0].audio]);
});

test("createSpeechPlaybackController requests TTS when the stream payload has text but no audio", async () => {
  const requestCalls = [];
  const revokedUrls = [];
  const fakeAudio = createFakeAudioFactory();

  const controller = createSpeechPlaybackController({
    getContext: () => ({
      normalizedBackendUrl: "http://127.0.0.1:8000",
      ttsEnabled: true,
      ttsProvider: "edge",
      ttsOverrides: {
        ttsOverrides: {
          voice: "alloy",
        },
      },
    }),
    requestTts: async (baseUrl, payload) => {
      requestCalls.push({ baseUrl, payload });
      return new Blob(["audio"], { type: "audio/mpeg" });
    },
    applyStageDirectives: () => {},
    stopCurrentAudio: () => {},
    createAudio: fakeAudio.factory,
    getActiveLive2DModel: () => null,
    buildBackendUrl: (baseUrl, targetUrl) => `${baseUrl}${targetUrl}`,
    audioManager: {
      setCurrentAudio: () => {},
      clearCurrentAudio: () => {},
    },
    getLipSyncPlaybackMode: () => "none",
    createRealtimeLipSyncCleanup: () => null,
    createObjectUrl: () => "blob:tts-generated",
    revokeObjectUrl: (source) => {
      revokedUrls.push(source);
    },
  });

  controller.enqueue({
    text: "你好呀",
    mode: "push",
  });

  await controller.waitForIdle();

  assert.deepEqual(requestCalls, [{
    baseUrl: "http://127.0.0.1:8000",
    payload: {
      text: "你好呀",
      provider: "edge",
      mode: "push",
      ttsOverrides: {
        voice: "alloy",
      },
    },
  }]);
  assert.equal(fakeAudio.created.length, 1);
  assert.equal(fakeAudio.created[0].audio.src, "blob:tts-generated");
  assert.deepEqual(revokedUrls, ["blob:tts-generated"]);
});

test("createSpeechPlaybackController drops stale queued playback after interrupt", async () => {
  const fakeAudio = createFakeAudioFactory();
  const stopCalls = [];
  let resolveTts;
  const pendingTts = new Promise((resolve) => {
    resolveTts = resolve;
  });

  const controller = createSpeechPlaybackController({
    getContext: () => ({
      normalizedBackendUrl: "http://127.0.0.1:8000",
      ttsEnabled: true,
      ttsProvider: "edge",
      ttsOverrides: {},
    }),
    requestTts: async () => pendingTts,
    applyStageDirectives: () => {},
    stopCurrentAudio: () => {
      stopCalls.push(true);
    },
    createAudio: fakeAudio.factory,
    getActiveLive2DModel: () => null,
    buildBackendUrl: (baseUrl, targetUrl) => `${baseUrl}${targetUrl}`,
    audioManager: {
      setCurrentAudio: () => {},
      clearCurrentAudio: () => {},
    },
    getLipSyncPlaybackMode: () => "none",
    createRealtimeLipSyncCleanup: () => null,
    createObjectUrl: () => "blob:stale",
    revokeObjectUrl: () => {},
  });

  controller.enqueue({
    text: "稍后播放",
    mode: "chat",
  });
  controller.interrupt();
  resolveTts(new Blob(["audio"], { type: "audio/mpeg" }));

  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(stopCalls.length, 1);
  assert.equal(fakeAudio.created.length, 0);
});
