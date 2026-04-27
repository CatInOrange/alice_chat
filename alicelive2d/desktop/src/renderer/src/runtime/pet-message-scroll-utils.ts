export function shouldScrollPetMessagesToBottom({
  previousSurface,
  nextSurface,
  previousMessageCount,
  nextMessageCount,
  previousLatestMessageId,
  nextLatestMessageId,
  previousExpanded,
  nextExpanded,
}) {
  if (nextSurface !== "chat") {
    return false;
  }

  if (previousSurface !== "chat") {
    return true;
  }

  if (nextMessageCount !== previousMessageCount) {
    return true;
  }

  if (nextLatestMessageId !== previousLatestMessageId) {
    return true;
  }

  if (previousExpanded !== nextExpanded) {
    return true;
  }

  return false;
}
