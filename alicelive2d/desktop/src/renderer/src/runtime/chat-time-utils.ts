function padTwoDigits(value) {
  return String(value).padStart(2, "0");
}

function normalizeTimestampInput(value) {
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value;
  }

  if (typeof value === "number" && Number.isFinite(value)) {
    const timestampMs = value > 1e12 ? value : value * 1000;
    const date = new Date(timestampMs);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  if (typeof value === "string" && value.trim()) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  return null;
}

function isSameLocalDay(left, right) {
  return left.getFullYear() === right.getFullYear()
    && left.getMonth() === right.getMonth()
    && left.getDate() === right.getDate();
}

export function formatChatMessageTimestamp(value, now = new Date()) {
  const messageDate = normalizeTimestampInput(value);
  const currentDate = normalizeTimestampInput(now);

  if (!messageDate || !currentDate) {
    return "";
  }

  const timeLabel = `${padTwoDigits(messageDate.getHours())}:${padTwoDigits(messageDate.getMinutes())}`;
  if (isSameLocalDay(messageDate, currentDate)) {
    return timeLabel;
  }

  return `${padTwoDigits(messageDate.getMonth() + 1)}/${padTwoDigits(messageDate.getDate())} ${timeLabel}`;
}

export function formatChatMessageMeta({
  speaker,
  timestamp,
  now = new Date(),
}) {
  const speakerLabel = String(speaker || "").trim();
  const timeLabel = formatChatMessageTimestamp(timestamp, now);

  if (speakerLabel && timeLabel) {
    return `${speakerLabel} · ${timeLabel}`;
  }

  return speakerLabel || timeLabel;
}

export function formatStreamingMessageMeta({
  speaker,
  timestamp,
  now = new Date(),
}) {
  return formatChatMessageMeta({
    speaker,
    timestamp,
    now,
  });
}
