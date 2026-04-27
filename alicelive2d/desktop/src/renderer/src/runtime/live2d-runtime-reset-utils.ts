export function resetLive2DRuntime({
  releaseDelegate,
  releaseGlManager,
  releaseLive2DManager,
}) {
  releaseDelegate?.();
  releaseGlManager?.();
  releaseLive2DManager?.();
}
