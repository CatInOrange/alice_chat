export async function capture(args = {}, ctx = {}) {
  const { api } = ctx;
  const sendTo = String(args.sendTo || "ai");
  const note = String(args.note || "").trim();
  const dataUrl = await api.desktop.capturePrimaryScreen();
  if (!dataUrl) {
    return { ok: false, error: "capture_failed" };
  }
  const attachment = api.utils.dataUrlToAttachment(dataUrl);

  if (sendTo === "ai") {
    await api.chat.sendToAI({
      text: note || "Screenshot captured.",
      attachments: [attachment],
      mode: "tool",
      historyText: "",
    });
    return { ok: true, result: { sent: "ai", image: { kind: "image", source: "capture" } } };
  }

  if (sendTo === "user") {
    await api.chat.sendToUser(note || "已截图", [attachment]);
    return { ok: true, result: { sent: "user", image: { kind: "image", source: "capture" } } };
  }

  await api.chat.sendToAI({
    text: note || "Screenshot captured.",
    attachments: [attachment],
    mode: "tool",
    historyText: "",
  });
  await api.chat.sendToUser(note || "已截图", [attachment]);
  return { ok: true, result: { sent: "both", image: { kind: "image", source: "capture" } } };
}
