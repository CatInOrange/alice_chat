export function getPetOverlayCenter({
  workArea,
  virtualBounds,
}) {
  return {
    x: Math.round(
      Number(workArea?.x || 0) - Number(virtualBounds?.x || 0) + Number(workArea?.width || 0) / 2,
    ),
    y: Math.round(
      Number(workArea?.y || 0) - Number(virtualBounds?.y || 0) + Number(workArea?.height || 0) / 2,
    ),
  };
}

export function getPetShellBackgroundStyle(background) {
  if (!background) {
    return {};
  }

  return {
    backgroundImage: `linear-gradient(rgba(251,247,243,0.18), rgba(244,236,228,0.5)), url(${background})`,
    backgroundSize: "cover",
    backgroundPosition: "center",
  };
}
