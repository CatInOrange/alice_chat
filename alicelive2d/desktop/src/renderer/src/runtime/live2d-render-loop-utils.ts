export function shouldRenderLive2DFrame({
  activeInstance,
  loopInstance,
  view,
  glContext,
}) {
  return activeInstance === loopInstance && Boolean(view) && Boolean(glContext);
}
