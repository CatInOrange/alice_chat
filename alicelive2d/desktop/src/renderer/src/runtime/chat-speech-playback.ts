import { waitForPlaybackQueue } from "./chat-playback-actions.ts";
import {
  createNextPlaybackVersion,
  isPlaybackVersionCurrent,
} from "./speech-runtime-utils.ts";

type SpeechMode = "chat" | "push";
type LipSyncPlaybackMode = "none" | "wav-handler" | "realtime";

interface SpeechPlaybackPayload {
  text?: string;
  audioUrl?: string;
  audioMimeType?: string;
  directives?: unknown[];
  mode?: SpeechMode;
}

interface AudioLike {
  crossOrigin?: string;
  ended?: boolean;
  addEventListener: (
    type: "ended" | "error",
    handler: () => void,
    options?: AddEventListenerOptions,
  ) => void;
  play: () => Promise<void>;
}

interface Live2DModelLike {
  _externalLipSyncValue: number | null;
  _wavFileHandler?: {
    start: (source: string) => void;
  } | null;
}

interface SpeechPlaybackContext {
  normalizedBackendUrl: string;
  ttsEnabled: boolean;
  ttsProvider: string;
  ttsOverrides?: Record<string, unknown>;
}

interface SpeechPlaybackAudioManager {
  setCurrentAudio: (
    audio: AudioLike,
    model: Live2DModelLike | null,
    cleanup?: (() => void) | null,
  ) => void;
  clearCurrentAudio: (audio: AudioLike) => void;
}

interface CreateSpeechPlaybackControllerOptions {
  getContext: () => SpeechPlaybackContext;
  requestTts: (baseUrl: string, payload: Record<string, unknown>) => Promise<Blob>;
  applyStageDirectives: (directives: unknown[]) => void;
  stopCurrentAudio: () => void;
  createAudio: (source: string) => AudioLike;
  getActiveLive2DModel: () => Live2DModelLike | null;
  buildBackendUrl: (baseUrl: string, targetUrl: string) => string;
  audioManager: SpeechPlaybackAudioManager;
  getLipSyncPlaybackMode: (payload: {
    audioMimeType?: string;
    audioSource?: string;
  }) => LipSyncPlaybackMode;
  createRealtimeLipSyncCleanup: (
    audio: AudioLike,
    model: Live2DModelLike | null,
  ) => (() => void) | null;
  createObjectUrl?: (blob: Blob) => string;
  revokeObjectUrl?: (source: string) => void;
  onQueueError?: (error: unknown) => void;
}

interface SpeechPlaybackController {
  enqueue: (payload: SpeechPlaybackPayload) => void;
  interrupt: () => void;
  waitForIdle: (onError?: (error: unknown) => void) => Promise<void>;
}

function isDirectAudioSource(source: string): boolean {
  return /^https?:\/\//i.test(source) || source.startsWith("blob:") || source.startsWith("data:");
}

async function playSpeechPayload(
  payload: SpeechPlaybackPayload,
  playbackVersion: number,
  options: CreateSpeechPlaybackControllerOptions,
  playbackState: {
    getVersion: () => number;
    getCurrentAudio: () => AudioLike | null;
    setCurrentAudio: (audio: AudioLike | null) => void;
    stopCurrentAudio: () => void;
  },
): Promise<void> {
  if (!isPlaybackVersionCurrent(playbackVersion, playbackState.getVersion())) {
    return;
  }

  options.applyStageDirectives(payload.directives || []);

  const context = options.getContext();
  let targetUrl = String(payload.audioUrl || "").trim();
  let targetMimeType = String(payload.audioMimeType || "").trim();
  let shouldRevoke = false;

  if (!targetUrl && payload.text && context.ttsEnabled) {
    const blob = await options.requestTts(context.normalizedBackendUrl, {
      text: payload.text,
      provider: context.ttsProvider,
      mode: payload.mode || "chat",
      ...(context.ttsOverrides || {}),
    });
    if (!isPlaybackVersionCurrent(playbackVersion, playbackState.getVersion())) {
      return;
    }
    targetUrl = (options.createObjectUrl || URL.createObjectURL)(blob);
    targetMimeType = blob.type || targetMimeType;
    shouldRevoke = true;
  }

  if (!targetUrl) {
    return;
  }

  await new Promise<void>((resolve) => {
    if (!isPlaybackVersionCurrent(playbackVersion, playbackState.getVersion())) {
      resolve();
      return;
    }

    playbackState.stopCurrentAudio();
    const model = options.getActiveLive2DModel();
    const audio = options.createAudio(
      isDirectAudioSource(targetUrl)
        ? targetUrl
        : options.buildBackendUrl(context.normalizedBackendUrl, targetUrl),
    );
    audio.crossOrigin = "anonymous";
    playbackState.setCurrentAudio(audio);

    let lipSyncCleanup: (() => void) | null = null;
    let finished = false;
    const finish = () => {
      if (finished) {
        return;
      }
      finished = true;
      if (shouldRevoke) {
        (options.revokeObjectUrl || URL.revokeObjectURL)(targetUrl);
      }
      if (playbackState.getCurrentAudio() === audio) {
        playbackState.setCurrentAudio(null);
      }
      options.audioManager.clearCurrentAudio(audio);
      resolve();
    };

    options.audioManager.setCurrentAudio(audio, model, () => {
      if (lipSyncCleanup) {
        lipSyncCleanup();
        lipSyncCleanup = null;
      }
      if (model) {
        model._externalLipSyncValue = null;
      }
    });

    audio.addEventListener("ended", finish, { once: true });
    audio.addEventListener("error", finish, { once: true });
    void audio.play()
      .then(() => {
        if (!isPlaybackVersionCurrent(playbackVersion, playbackState.getVersion())) {
          finish();
          return;
        }

        const lipSyncMode = options.getLipSyncPlaybackMode({
          audioMimeType: targetMimeType,
          audioSource: targetUrl,
        });
        if (model && lipSyncMode === "wav-handler" && model._wavFileHandler) {
          model._wavFileHandler.start(String((audio as { src?: string }).src || targetUrl));
        } else if (model && lipSyncMode === "realtime") {
          lipSyncCleanup = options.createRealtimeLipSyncCleanup(audio, model);
        }
      })
      .catch(() => finish());
  });
}

export function createSpeechPlaybackController(
  options: CreateSpeechPlaybackControllerOptions,
): SpeechPlaybackController {
  let playbackQueue: Promise<void> = Promise.resolve();
  let playbackVersion = 0;
  let currentAudio: AudioLike | null = null;

  const playbackState = {
    getVersion: () => playbackVersion,
    getCurrentAudio: () => currentAudio,
    setCurrentAudio: (audio: AudioLike | null) => {
      currentAudio = audio;
    },
    stopCurrentAudio: () => {
      options.stopCurrentAudio();
      currentAudio = null;
    },
  };

  return {
    enqueue(payload) {
      const queueVersion = playbackVersion;
      playbackQueue = playbackQueue
        .then(() => playSpeechPayload(payload, queueVersion, options, playbackState))
        .catch((error) => {
          options.onQueueError?.(error);
        });
    },
    interrupt() {
      playbackVersion = createNextPlaybackVersion(playbackVersion);
      playbackQueue = Promise.resolve();
      playbackState.stopCurrentAudio();
    },
    waitForIdle(onError) {
      return waitForPlaybackQueue(playbackQueue, onError);
    },
  };
}
