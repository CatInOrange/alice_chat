export function getPetToggleButtonState(petSurface) {
  return {
    ariaLabel: petSurface === "hidden" ? "打开对话" : "隐藏对话",
    showText: false,
  };
}
