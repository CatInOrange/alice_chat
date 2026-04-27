import { useCallback } from "react";
import { toaster } from "@/shared/ui/toaster";

export function useSendAudio() {
  const sendAudioPartition = useCallback(
    async (audio: Float32Array) => {
      void audio;
      toaster.create({
        title: '当前版本暂未接入语音输入上传',
        type: 'warning',
        duration: 2000,
      });
    },
    [],
  );

  return {
    sendAudioPartition,
  };
}
