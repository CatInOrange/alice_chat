import { audioManager } from "@/utils/audio-manager";
import {
  createRealtimeLipSyncCleanup,
  getActiveLive2DModel,
  getLipSyncPlaybackMode,
} from "@/runtime/live2d-audio-utils";

interface PlayTeaseAudioOptions {
  audioUrl: string;
  blockWhenBusy?: boolean;
}

function clearAudioSource(audio: HTMLAudioElement) {
  try {
    audio.pause();
    audio.src = "";
    audio.load();
  } catch {
    // noop
  }
}

export function playTeaseAudio({
  audioUrl,
  blockWhenBusy = true,
}: PlayTeaseAudioOptions): boolean {
  const source = String(audioUrl || "").trim();
  if (!source) {
    return false;
  }

  if (blockWhenBusy && audioManager.hasCurrentAudio()) {
    console.info("[TeaseAudio] skipped because other audio is playing", { audioUrl: source });
    return false;
  }

  const audio = new Audio(source);
  audio.crossOrigin = "anonymous";

  const model = getActiveLive2DModel();
  const lipSyncMode = getLipSyncPlaybackMode({
    audioMimeType: source.toLowerCase().endsWith(".wav") ? "audio/wav" : "audio/mpeg",
    audioSource: source,
  });

  let cleanup: (() => void) | null = null;
  let finished = false;

  const finish = () => {
    if (finished) {
      return;
    }
    finished = true;
    if (cleanup) {
      try {
        cleanup();
      } catch {
        // noop
      }
      cleanup = null;
    }
    if (model) {
      model._externalLipSyncValue = null;
    }
    audioManager.clearCurrentAudio(audio);
  };

  audioManager.setCurrentAudio(audio, model, () => {
    if (cleanup) {
      cleanup();
      cleanup = null;
    }
    if (model) {
      model._externalLipSyncValue = null;
    }
    clearAudioSource(audio);
  });

  audio.addEventListener("ended", finish, { once: true });
  audio.addEventListener("error", () => {
    console.warn("[TeaseAudio] audio element error", { audioUrl: source });
    finish();
  }, { once: true });

  void audio.play()
    .then(() => {
      if (model && lipSyncMode === "wav-handler" && model._wavFileHandler) {
        model._wavFileHandler.start(String(audio.src || source));
      } else if (model && lipSyncMode === "realtime") {
        cleanup = createRealtimeLipSyncCleanup(audio, model);
      }
    })
    .catch((error) => {
      console.warn("[TeaseAudio] audio.play failed", { audioUrl: source, error });
      finish();
    });

  return true;
}
