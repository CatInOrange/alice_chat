export function resolvePetShellHoverState({ petSurface, isHovering }) {
  if (petSurface === "hidden") {
    return false;
  }

  return isHovering;
}

export function resolvePetAnchorUpdate({
  currentAnchor,
  nextAnchor,
  isLocked,
}) {
  return isLocked ? currentAnchor : nextAnchor;
}

export function shouldUpdatePetAnchor({
  currentAnchor,
  nextAnchor,
}) {
  return (
    currentAnchor?.x !== nextAnchor?.x ||
    currentAnchor?.y !== nextAnchor?.y
  );
}

export function getDraggedPetAnchor({
  startAnchor,
  dragStart,
  pointer,
}) {
  return {
    x: startAnchor.x + (pointer.x - dragStart.x),
    y: startAnchor.y + (pointer.y - dragStart.y),
  };
}
