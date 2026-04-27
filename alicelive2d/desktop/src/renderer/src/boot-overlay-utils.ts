function getOverlayMarkup(status, message) {
  return `
    <div style="
      min-height: 100vh;
      width: 100vw;
      display: flex;
      align-items: center;
      justify-content: center;
      background:
        radial-gradient(circle at top, rgba(251, 113, 133, 0.22), transparent 35%),
        linear-gradient(180deg, #0f172a 0%, #020617 100%);
      color: #f8fafc;
      font-family: 'Segoe UI', 'PingFang SC', sans-serif;
    ">
      <div style="
        width: min(440px, calc(100vw - 48px));
        padding: 28px 24px;
        border-radius: 24px;
        background: rgba(2, 6, 23, 0.82);
        border: 1px solid rgba(255,255,255,0.08);
        box-shadow: 0 18px 60px rgba(0,0,0,0.28);
        backdrop-filter: blur(18px);
      ">
        <div style="
          font-size: 13px;
          letter-spacing: 0.18em;
          text-transform: uppercase;
          color: rgba(248,250,252,0.68);
          margin-bottom: 10px;
        ">OpenClaw</div>
        <div style="
          font-size: 22px;
          font-weight: 700;
          margin-bottom: 10px;
        ">${status === "loading" ? "正在启动桌宠前端" : "启动失败"}</div>
        <div style="
          font-size: 14px;
          line-height: 1.7;
          color: rgba(248,250,252,0.82);
          white-space: pre-wrap;
        ">${message}</div>
      </div>
    </div>
  `;
}

export function ensureBootOverlay(document, { status, message }) {
  if (!document?.body) {
    return null;
  }

  let overlay = document.getElementById("boot-overlay");
  if (!overlay) {
    overlay = document.createElement("div");
    overlay.id = "boot-overlay";
    overlay.style.position = "fixed";
    overlay.style.inset = "0";
    overlay.style.zIndex = "2147483647";
    overlay.style.pointerEvents = "auto";
    document.body.appendChild(overlay);
  }

  overlay.innerHTML = getOverlayMarkup(status, message);
  return overlay;
}

export function hideBootOverlay(document) {
  const overlay = document?.getElementById?.("boot-overlay");
  overlay?.remove?.();
}
