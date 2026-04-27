export async function say(args = {}, ctx = {}) {
  const { api } = ctx;
  const text = String(args.text || "").trim() || "（空消息）";
  await api.ui.sendMessage(text, []);
  return { ok: true, result: { ok: true } };
}
