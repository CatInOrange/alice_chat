import { WebSocketServer } from 'ws';
import fsSync from 'node:fs';
import path from 'node:path';
import { createChannelReplyPipeline } from 'openclaw/plugin-sdk/channel-reply-pipeline';

const ALICECHAT_BACKEND_CONFIG_PATH = process.env.ALICECHAT_BACKEND_CONFIG_PATH || '/root/.openclaw/AliceChat/backend/config.json';
const ALICECHAT_CONFIG_PATH = process.env.ALICECHAT_CONFIG_PATH || '/root/.openclaw/AliceChat/config.json';
const DEFAULT_ALICECHAT_API_BASE_URL = process.env.ALICECHAT_API_BASE_URL || 'http://127.0.0.1:18081';

const CHANNEL_ID = 'alicechat';
const FRAME_AUDIT_ENABLED = !['', '0', 'false', 'no', 'off'].includes(String(process.env.ALICECHAT_FRAME_AUDIT || '1').toLowerCase());
const FRAME_AUDIT_DIR = process.env.ALICECHAT_FRAME_AUDIT_DIR || '/root/.openclaw/AliceChat/data/frame-audit';

function auditFrame(stream, direction, frame, meta = {}) {
  if (!FRAME_AUDIT_ENABLED) return;
  try {
    fsSync.mkdirSync(FRAME_AUDIT_DIR, { recursive: true });
    const now = new Date();
    const day = now.toISOString().slice(0, 10).replace(/-/g, '');
    const record = {
      id: `${Date.now()}-${Math.random().toString(16).slice(2, 10)}`,
      ts: Date.now() / 1000,
      iso: now.toISOString(),
      stream,
      direction,
      frameType: String(frame?.type || (meta as any).frameType || ''),
      meta,
      frame,
    };
    fsSync.appendFileSync(
      path.join(FRAME_AUDIT_DIR, `${day}.jsonl`),
      `${JSON.stringify(record)}\n`,
      'utf8',
    );
  } catch (error) {
    console.error('[AliceChat][frame-audit] write failed', error);
  }
}
const activeServers = new Map();
const activeClients = new Map();

function waitUntilAbort(signal, onAbort?: () => void) {
  return new Promise<void>((resolve) => {
    if (signal.aborted) {
      onAbort?.();
      resolve();
      return;
    }
    signal.addEventListener(
      'abort',
      () => {
        onAbort?.();
        resolve();
      },
      { once: true },
    );
  });
}

function buildSessionKey(agentId, sessionName) {
  return `agent:${agentId}:${sessionName}`;
}

function toReplyImage(att) {
  if (!att) return null;
  const mimeType = att.mimeType || att.mediaType || att.mime_type || 'image/png';
  if (att.content) {
    const data = String(att.content).replace(/^data:[^,]+,/, '').replace(/\s+/g, '');
    return { type: 'image', data, mimeType };
  }
  return null;
}

function materializeInboundMediaList(attachments) {
  const list = [];
  for (const att of Array.isArray(attachments) ? attachments : []) {
    if (!att) continue;
    const mimeType = String(att.mimeType || att.mediaType || att.mime_type || '');
    if (!mimeType.startsWith('image/')) continue;
    const localPath = String(att.path || '').trim();
    if (localPath && path.isAbsolute(localPath)) {
      list.push({ path: localPath, contentType: mimeType || undefined });
      continue;
    }
    const url = String(att.url || '').trim();
    if (url.startsWith('/')) list.push({ path: url, contentType: mimeType || undefined });
  }
  return list;
}

function buildAgentMediaPayload(mediaList) {
  const first = mediaList[0];
  const mediaPaths = mediaList.map((media) => media.path).filter(Boolean);
  const mediaTypes = mediaList.map((media) => media.contentType).filter(Boolean);
  return {
    MediaPath: first?.path,
    MediaType: first?.contentType ?? undefined,
    MediaUrl: first?.path,
    MediaPaths: mediaPaths.length > 0 ? mediaPaths : undefined,
    MediaUrls: mediaPaths.length > 0 ? mediaPaths : undefined,
    MediaTypes: mediaTypes.length > 0 ? mediaTypes : undefined,
  };
}

function classifyMedia(url, audioAsVoice) {
  if (audioAsVoice) return 'audio';
  if (/\.(mp3|wav|ogg|m4a|aac|webm)(\?|$)/i.test(String(url || ''))) return 'audio';
  return 'image';
}

function toPushAttachmentRef(mediaUrl, audioAsVoice) {
  const raw = String(mediaUrl || '').trim();
  if (!raw) return null;
  const attachment = {
    type: classifyMedia(raw, audioAsVoice),
    audioAsVoice: !!audioAsVoice,
  };
  if (/^data:/i.test(raw)) {
    return { ...attachment, url: raw };
  }
  if (/^file:/i.test(raw)) {
    try {
      const fileUrl = new URL(raw);
      return { ...attachment, path: decodeURIComponent(fileUrl.pathname || '') };
    } catch {
      return { ...attachment, url: raw };
    }
  }
  if (raw.startsWith('/')) {
    return { ...attachment, path: raw };
  }
  return { ...attachment, url: raw };
}

function registerClient(activeClients, client) {
  const cfg = client.cfg;
  const backendPrefix = cfg.backendPrefix || 'alicechat:backend:';
  const userPrefix = cfg.userPrefix || 'alicechat:user:';
  const keys = new Set([
    client.senderId,
    client.target,
    `${backendPrefix}${client.accountId}`,
    `${userPrefix}${client.senderId}`,
  ].filter(Boolean));
  for (const key of keys) activeClients.set(String(key), client);
  client._keys = [...keys];
}

function unregisterClient(activeClients, client) {
  for (const key of client?._keys || []) {
    const cur = activeClients.get(key);
    if (cur === client) activeClients.delete(key);
  }
}

let cachedAliceChatApiSettings = null;

async function loadAliceChatApiSettings() {
  if (cachedAliceChatApiSettings) {
    return cachedAliceChatApiSettings;
  }

  let appPassword = String(process.env.ALICECHAT_APP_PASSWORD || '').trim();
  let baseUrl = String(process.env.ALICECHAT_API_BASE_URL || '').trim();

  const configPaths = [
    ALICECHAT_BACKEND_CONFIG_PATH,
    ALICECHAT_CONFIG_PATH,
  ].filter(Boolean);

  for (const configPath of configPaths) {
    try {
      const raw = await fsSync.promises.readFile(configPath, 'utf8');
      const parsed = JSON.parse(raw);
      if (!baseUrl) {
        const server = parsed?.server || {};
        const host = String(server.host || '127.0.0.1').trim();
        const normalizedHost = host === '0.0.0.0' ? '127.0.0.1' : host || '127.0.0.1';
        const port = Number(server.port || 18081);
        baseUrl = `http://${normalizedHost}:${port}`;
      }
      if (!appPassword) {
        appPassword = String(parsed?.auth?.appAccessPassword || '').trim();
      }
      if (baseUrl && appPassword) break;
    } catch (error) {
      // ignore and continue to next config source
    }
  }

  cachedAliceChatApiSettings = {
    baseUrl: baseUrl || DEFAULT_ALICECHAT_API_BASE_URL,
    appPassword,
  };
  return cachedAliceChatApiSettings;
}

async function callAliceChatApi(method, routePath, payload) {
  const { baseUrl, appPassword } = await loadAliceChatApiSettings();
  if (!appPassword) {
    throw new Error('AliceChat appAccessPassword 未配置；请设置 ALICECHAT_APP_PASSWORD，或检查 backend/config.json / config.json');
  }

  const url = new URL(routePath, `${baseUrl.replace(/\/$/, '')}/`).toString();
  const response = await fetch(url, {
    method,
    headers: {
      'content-type': 'application/json',
      'x-alicechat-password': appPassword,
    },
    body: payload === undefined ? undefined : JSON.stringify(payload),
  });

  const text = await response.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (error) {
      data = { raw: text };
    }
  }

  if (!response.ok) {
    const detail = data && typeof data === 'object' ? JSON.stringify(data) : text;
    throw new Error(`AliceChat API ${method} ${routePath} 失败 (${response.status}): ${detail || response.statusText}`);
  }

  return data;
}

const MUSIC_ARTWORK_TONES = ['twilight', 'sunset', 'aurora', 'ocean', 'rose', 'midnight'];

function normalizeMusicArtworkTone(value, fallback = 'aurora') {
  const tone = String(value || '').trim();
  return MUSIC_ARTWORK_TONES.includes(tone) ? tone : fallback;
}

function normalizeMusicTrack(track, fallbackIdPrefix, index = 0, fallbackTone = 'aurora') {
  return {
    id: String(track?.id || `${String(fallbackIdPrefix || 'music-action')}:track:${index}`),
    title: String(track?.title || '').trim(),
    artist: String(track?.artist || '').trim(),
    album: String(track?.album || '').trim(),
    category: String(track?.category || '').trim(),
    description: String(track?.description || '').trim(),
    artworkTone: normalizeMusicArtworkTone(track?.artworkTone, fallbackTone),
    artworkUrl: String(track?.artworkUrl || '').trim() || undefined,
    preferredSourceId: String(track?.preferredSourceId || '').trim() || undefined,
    sourceTrackId: String(track?.sourceTrackId || '').trim() || undefined,
    durationMs: Number(track?.durationMs || 0),
  };
}

function normalizeMusicTracks(rawTracks, fallbackIdPrefix, fallbackTone = 'aurora') {
  const tracks = Array.isArray(rawTracks) ? rawTracks : [];
  return tracks
    .map((track, index) => normalizeMusicTrack(track, fallbackIdPrefix, index, fallbackTone))
    .filter((track) => track.title && track.artist);
}

function normalizeMusicPlaylistRef(rawPlaylist, fallbackTrackCount = 0) {
  if (!rawPlaylist || typeof rawPlaylist !== 'object') return null;
  const id = String(rawPlaylist.id || '').trim();
  const title = String(rawPlaylist.title || '').trim();
  if (!id || !title) return null;
  return {
    id,
    title,
    subtitle: String(rawPlaylist.subtitle || '').trim(),
    tag: String(rawPlaylist.tag || 'AI').trim() || 'AI',
    trackCount: Number(rawPlaylist.trackCount || fallbackTrackCount || 0),
    artworkTone: normalizeMusicArtworkTone(rawPlaylist.artworkTone, 'aurora'),
    isAiGenerated: rawPlaylist.isAiGenerated !== false,
  };
}

function normalizeMusicPlaylistDraft(rawDraft, fallbackId) {
  const nowSeconds = Date.now() / 1000;
  const tracks = normalizeMusicTracks(rawDraft?.tracks, fallbackId, rawDraft?.artworkTone || 'aurora');
  if (!tracks.length) return null;
  return {
    id: String(rawDraft?.id || fallbackId || `ai-playlist:${Date.now()}`).trim(),
    title: String(rawDraft?.title || '').trim(),
    subtitle: String(rawDraft?.subtitle || '').trim(),
    description: String(rawDraft?.description || '').trim(),
    tag: String(rawDraft?.tag || 'AI').trim() || 'AI',
    artworkTone: normalizeMusicArtworkTone(rawDraft?.artworkTone, 'aurora'),
    isAiGenerated: rawDraft?.isAiGenerated !== false,
    tracks,
    createdAt: Number(rawDraft?.createdAt || nowSeconds),
    updatedAt: Number(rawDraft?.updatedAt || nowSeconds),
  };
}

function playlistDraftToPlaylistRef(draft) {
  if (!draft || typeof draft !== 'object') return null;
  const title = String(draft.title || '').trim();
  if (!title) return null;
  return {
    id: String(draft.id || '').trim(),
    title,
    subtitle: String(draft.subtitle || '').trim(),
    tag: String(draft.tag || 'AI').trim() || 'AI',
    trackCount: Array.isArray(draft.tracks) ? draft.tracks.length : 0,
    artworkTone: normalizeMusicArtworkTone(draft.artworkTone, 'aurora'),
    isAiGenerated: draft.isAiGenerated !== false,
  };
}

function createBridgeServer(ctx) {
  const port = Number(ctx.account.websocketPort || 18791);
  const host = String(ctx.account.websocketHost || '127.0.0.1');
  const channelRuntime = ctx.channelRuntime;
  if (!channelRuntime) throw new Error('channelRuntime unavailable; OpenClaw version too old');

  const channelLabel = String(ctx.account.channelLabel || 'AliceChat');
  const providerId = String(ctx.account.providerId || 'alicechat');
  const backendPrefix = String(ctx.account.backendPrefix || 'alicechat:backend:');
  const userPrefix = String(ctx.account.userPrefix || 'alicechat:user:');

  const wss = new WebSocketServer({ host, port });

  async function processChatRequest(ws, frame, cfg) {
    auditFrame('gateway_backend_ws', 'backend->gateway', frame, {
      phase: 'gateway_recv_chat_request',
      accountId: String(ctx.accountId || 'default'),
    });
    const requestId = String(frame.requestId || '');
    const text = String(frame.text || '');
    const requestedAgent = String(frame.agent || 'main').trim() || 'main';
    const requestedSession = String(frame.session || 'main').trim() || 'main';
    const senderId = String(frame.senderId || 'alicechat-user');
    const senderName = String(frame.senderName || 'AliceChat User');
    const conversationLabel = String(frame.conversationLabel || requestedSession);
    const accountId = String(ctx.accountId || 'default');
    const sessionKey = String(frame.sessionKey || buildSessionKey(requestedAgent, requestedSession));
    const attachments = Array.isArray(frame.attachments) ? frame.attachments : [];
    const images = Array.isArray(frame.images) ? frame.images : attachments.map(toReplyImage).filter(Boolean);
    const agentMedia = frame.agentMedia && typeof frame.agentMedia === 'object'
      ? frame.agentMedia
      : buildAgentMediaPayload(materializeInboundMediaList(attachments));

    const currentCfg = ctx.cfg;
    const route = channelRuntime.routing.resolveAgentRoute({
      cfg: currentCfg,
      channel: CHANNEL_ID,
      accountId,
      peer: { kind: 'direct', id: senderId },
    });
    const agentId = requestedAgent || route.agentId;

    const instructionText = String(frame.instructionText || '').trim();
    const agentBodyText = instructionText
      ? `[System Guidance]\n${instructionText}\n\n[User Message]\n${text}`
      : text;

    const body = channelRuntime.reply.formatAgentEnvelope({
      channel: channelLabel,
      from: senderName,
      timestamp: Date.now(),
      envelope: channelRuntime.reply.resolveEnvelopeFormatOptions(currentCfg),
      body: text,
    });

    const inboundCtx = channelRuntime.reply.finalizeInboundContext({
      Body: body,
      BodyForAgent: agentBodyText,
      RawBody: text,
      CommandBody: agentBodyText,
      From: `${userPrefix}${senderId}`,
      To: `${backendPrefix}${accountId}`,
      SessionKey: sessionKey,
      AccountId: accountId,
      ChatType: 'direct',
      ConversationLabel: conversationLabel,
      SenderName: senderName,
      SenderId: senderId,
      Provider: providerId,
      Surface: providerId,
      MessageSid: requestId,
      OriginatingChannel: CHANNEL_ID,
      OriginatingTo: `${backendPrefix}${accountId}`,
      AgentId: agentId,
      ...agentMedia,
    });

    const storePath = channelRuntime.session.resolveStorePath(currentCfg.session?.store, { agentId });
    await channelRuntime.session.recordInboundSession({
      storePath,
      sessionKey: inboundCtx.SessionKey ?? sessionKey,
      ctx: inboundCtx,
      onRecordError: (err) => ctx.log?.warn?.(`Failed updating session meta: ${String(err)}`),
    });

    let frameSeq = 0;
    let replyFinalSent = false;
    let runFinalSent = false;
    let officialPreviewText = '';
    let officialFinalPayload = null;
    const sendBridgeFrame = (outFrame, phase) => {
      const frameType = String(outFrame?.type || '');
      if (runFinalSent) {
        console.warn(`[AliceChat] frame emitted after run_final requestId=${requestId} type=${frameType}`);
      }
      const frameWithSeq = {
        ...outFrame,
        seq: ++frameSeq,
      };
      if (frameType === 'chat.reply_final') replyFinalSent = true;
      if (frameType === 'chat.run_final') runFinalSent = true;
      auditFrame('gateway_backend_ws', 'gateway->backend', frameWithSeq, {
        phase,
        accountId,
        requestId,
        sessionKey,
        agent: agentId,
      });
      ws.send(JSON.stringify(frameWithSeq));
    };

    const emitReplyFinalIfNeeded = (finishReason = 'completed') => {
      if (replyFinalSent) return;
      const finalText = String(officialFinalPayload?.text ?? officialPreviewText ?? '').trim();
      const finalMedia = Array.isArray(officialFinalPayload?.media) ? officialFinalPayload.media : [];
      sendBridgeFrame({
        type: 'chat.reply_final',
        requestId,
        reply: finalText,
        media: finalMedia,
        state: 'final',
        finishReason,
        sessionKey,
        agent: agentId,
      }, 'gateway_send_chat_reply_final');
    };

    sendBridgeFrame({ type: 'chat.accepted', requestId, sessionKey, agent: agentId }, 'gateway_send_chat_accepted');

    const { onModelSelected, ...replyPipeline } = createChannelReplyPipeline({
      cfg: currentCfg,
      agentId,
      channel: CHANNEL_ID,
      accountId,
    });

    try {
      const dispatchResult = await channelRuntime.reply.dispatchReplyWithBufferedBlockDispatcher({
        ctx: inboundCtx,
        cfg: currentCfg,
        dispatcherOptions: {
          ...replyPipeline,
          onReplyStart: () => {
            sendBridgeFrame({ type: 'chat.reply_start', requestId }, 'gateway_send_chat_reply_start');
          },
          deliver: async (payload, info) => {
            const text = String(payload?.text ?? payload?.body ?? '').trim();
            const payloadKind = String(info?.kind || payload?.kind || 'block');
            const mediaUrls = Array.isArray(payload?.mediaUrls)
              ? payload.mediaUrls.filter(Boolean)
              : payload?.mediaUrl
                ? [payload.mediaUrl]
                : [];
            const finalMedia = mediaUrls.map((mediaUrl) => ({
              url: mediaUrl,
              type: classifyMedia(mediaUrl, payload?.audioAsVoice),
              audioAsVoice: !!payload?.audioAsVoice,
            }));
            if (payloadKind === 'final') {
              officialFinalPayload = {
                text: text || officialPreviewText,
                media: finalMedia,
              };
              if (text) {
                officialPreviewText = text;
              }
            } else if (text) {
              officialPreviewText = payloadKind === 'block'
                ? `${officialPreviewText}${text}`
                : text;
            }
            sendBridgeFrame({
              type: 'chat.raw_deliver',
              requestId,
              payloadKind,
              payload: {
                text,
                body: text,
                mediaUrl: mediaUrls[0] || '',
                mediaUrls,
                audioAsVoice: !!payload?.audioAsVoice,
              },
            }, 'gateway_send_chat_raw_deliver');
          },
        },
        replyOptions: {
          images,
          onModelSelected,
          onPartialReply: async (payload) => {
            const nextText = String(payload?.text ?? '').trim();
            if (!nextText) return;
            officialPreviewText = nextText;
            sendBridgeFrame({
              type: 'chat.raw_partial',
              requestId,
              text: nextText,
            }, 'gateway_send_chat_raw_partial');
          },
          onReasoningStream: async (payload) => {
            const text = String(payload?.text ?? '').trim();
            if (!text) return;
            sendBridgeFrame({
              type: 'chat.raw_reasoning',
              requestId,
              text,
            }, 'gateway_send_chat_raw_reasoning');
          },
          onAgentEvent: async (evt) => {
            sendBridgeFrame({
              type: 'chat.raw_agent_event',
              requestId,
              event: evt,
            }, 'gateway_send_chat_raw_agent_event');
          },
        },
      });

      if (dispatchResult?.queuedFinal || officialFinalPayload || officialPreviewText) {
        emitReplyFinalIfNeeded('completed');
      }
      sendBridgeFrame({
        type: 'chat.run_final',
        requestId,
        runState: 'completed',
        hadReplyFinal: replyFinalSent,
        reason: '',
        sessionKey,
        agent: agentId,
        stats: dispatchResult?.counts || {},
      }, 'gateway_send_chat_run_final');
    } catch (error) {
      if (replyFinalSent) {
        sendBridgeFrame({
          type: 'chat.run_final',
          requestId,
          runState: 'failed',
          hadReplyFinal: true,
          reason: error?.message || 'bridge_error',
          sessionKey,
          agent: agentId,
        }, 'gateway_send_chat_run_final_failed');
        return;
      }
      throw error;
    }
  }

  wss.on('connection', (ws, req) => {
    const remoteAddress = req.socket.remoteAddress || '未知IP';
    try {
      const url = new URL(`http://${req.headers.host || 'localhost'}${req.url || ''}`);
      const token = url.searchParams.get('token');

      const expectedToken = String(process.env.ALICECHAT_SECRET || 'alicechat-secret-token');
      if (!token || token.length < 16 || token !== expectedToken) {
        console.error(`[AliceChat] Unauthorized connection attempt from ${req.socket.remoteAddress}`);
        ws.close(1008, 'Authentication failed');
        return;
      }

      console.log(`[AliceChat] Backend authenticated successfully from ${req.socket.remoteAddress}`);
    } catch (err) {
      console.error(`[AliceChat] Invalid connection request from ${req.socket.remoteAddress}`);
      ws.close(1008, 'Invalid request');
      return;
    }

    let client = null;
    const clientCfg = {
      channelLabel,
      providerId,
      backendPrefix,
      userPrefix,
    };

    ws.on('close', () => {
      if (client) {
        unregisterClient(activeClients, client);
      }
    });

    ws.on('message', async (raw) => {
      let frame;

      try {
        frame = JSON.parse(String(raw));
        auditFrame('gateway_backend_ws', 'backend->gateway', frame, {
          phase: 'gateway_ws_message',
          accountId: String(ctx.accountId || 'default'),
          remoteAddress,
        });
      } catch (err) {
        console.warn(`[AliceChat] 收到无效 JSON 来自 ${remoteAddress}`);
        ws.send(JSON.stringify({ type: 'chat.error', error: 'invalid_json' }));
        return;
      }

      try {
        switch (frame.type) {
          case 'bridge.register':
            client = {
              ws,
              accountId: String(ctx.accountId || 'default'),
              senderId: String(frame.senderId || 'alicechat-user'),
              senderName: String(frame.senderName || 'AliceChat User'),
              target: String(frame.target || frame.senderId || 'alicechat-user'),
              cfg: clientCfg,
            };

            registerClient(activeClients, client);

            ws.send(JSON.stringify({
              type: 'bridge.registered',
              target: client.target,
              senderId: client.senderId,
            }));
            break;

          case 'chat.request':
            await processChatRequest(ws, frame, clientCfg);
            break;

          case 'ping':
            ws.send(JSON.stringify({
              type: 'pong',
              ts: Date.now(),
            }));
            break;

          default:
            ws.send(JSON.stringify({
              type: 'chat.error',
              requestId: frame?.requestId,
              error: 'unsupported_frame_type',
            }));
        }
      } catch (error) {
        console.error(`[AliceChat] 处理消息时发生错误 来自 ${remoteAddress}：`, error);

        ws.send(JSON.stringify({
          type: 'chat.error',
          requestId: frame?.requestId,
          error: error?.message || 'bridge_error',
        }));
      }
    });

    ws.on('error', (err) => {
      console.error(`[AliceChat] WebSocket 错误 来自 ${remoteAddress}：`, err);
    });
  });

  return {
    async stop() {
      await new Promise<void>((resolve, reject) => {
        wss.close((err) => (err ? reject(err) : resolve()));
      });
    },
  };
}

const alicechatPlugin = {
  id: CHANNEL_ID,
  meta: {
    id: CHANNEL_ID,
    label: 'AliceChat',
    selectionLabel: 'AliceChat Bridge',
    blurb: 'Bridge channel between OpenClaw and the AliceChat Python backend.',
    order: 96,
    docsPath: '/channels/alicechat',
    aliases: ['alicechat'],
  },
  capabilities: {
    chatTypes: ['direct'],
    media: {
      images: { send: true, receive: true },
      audio: { send: true, receive: true },
      video: { send: false, receive: false },
      documents: { send: false, receive: false },
    },
    reactions: { supported: false },
    editing: { supported: false },
    deletion: { supported: false },
    threads: { supported: false },
    typing: { supported: true },
    streaming: { supported: true },
  },
  config: {
    listAccountIds: (cfg) => (cfg.channels?.alicechat?.enabled ? ['default'] : []),
    resolveAccount: (cfg, accountId) => ({
      accountId: accountId || 'default',
      enabled: !!cfg.channels?.alicechat?.enabled,
      websocketHost: cfg.channels?.alicechat?.websocketHost || '127.0.0.1',
      websocketPort: Number(cfg.channels?.alicechat?.websocketPort || 18791),
      channelLabel: cfg.channels?.alicechat?.channelLabel || 'AliceChat',
      providerId: cfg.channels?.alicechat?.providerId || 'alicechat',
      backendPrefix: cfg.channels?.alicechat?.backendPrefix || 'alicechat:backend:',
      userPrefix: cfg.channels?.alicechat?.userPrefix || 'alicechat:user:',
    }),
    inspectAccount: (cfg, accountId) => ({
      accountId: accountId || 'default',
      enabled: !!cfg.channels?.alicechat?.enabled,
      websocketHost: cfg.channels?.alicechat?.websocketHost || '127.0.0.1',
      websocketPort: Number(cfg.channels?.alicechat?.websocketPort || 18791),
      channelLabel: cfg.channels?.alicechat?.channelLabel || 'AliceChat',
      providerId: cfg.channels?.alicechat?.providerId || 'alicechat',
      backendPrefix: cfg.channels?.alicechat?.backendPrefix || 'alicechat:backend:',
      userPrefix: cfg.channels?.alicechat?.userPrefix || 'alicechat:user:',
    }),
  },
  configSchema: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        enabled: { type: 'boolean', default: false },
        websocketHost: { type: 'string', default: '127.0.0.1' },
        websocketPort: { type: 'number', default: 18791 },
        channelLabel: { type: 'string', default: 'AliceChat' },
        providerId: { type: 'string', default: 'alicechat' },
        backendPrefix: { type: 'string', default: 'alicechat:backend:' },
        userPrefix: { type: 'string', default: 'alicechat:user:' },
      },
    },
    uiHints: {
      enabled: { label: '启用 AliceChat channel bridge' },
      websocketHost: { label: 'WebSocket 主机', placeholder: '127.0.0.1' },
      websocketPort: { label: 'WebSocket 端口', placeholder: '18791' },
      channelLabel: { label: 'Channel 标签' },
      providerId: { label: 'Provider ID' },
      backendPrefix: { label: '后端 key 前缀' },
      userPrefix: { label: '用户 key 前缀' },
    },
  },
  messaging: {
    normalizeTarget: (raw) => String(raw || '').trim() || undefined,
    targetResolver: {
      hint: 'Use alicechat-user or alicechat:backend:default for the connected AliceChat client.',
      looksLikeId: (raw, normalized) => Boolean((normalized || raw || '').trim()),
    },
  },
  outbound: {
    deliveryMode: 'direct',
    resolveTarget: ({ to, accountId }) => {
      const target = String(to || '').trim();
      if (!target) return { ok: false, error: new Error('AliceChat target is required') };
      const resolved = activeClients.get(target) || activeClients.get(`alicechat:backend:${accountId || 'default'}`);
      if (!resolved) return { ok: false, error: new Error(`Unknown target "${target}" for AliceChat.`) };
      return { ok: true, to: target };
    },
    sendText: async (ctx) => {
      const client = activeClients.get(ctx.to) || activeClients.get(`alicechat:backend:${ctx.accountId || 'default'}`);
      if (!client?.ws) throw new Error(`AliceChat target not connected: ${ctx.to}`);
      client.ws.send(JSON.stringify({
        type: 'push.message',
        text: String(ctx.text || ''),
        attachments: [],
        from: 'assistant',
        ts: Date.now(),
        providerId: String(client.cfg?.providerId || CHANNEL_ID),
        accountId: ctx.accountId || 'default',
      }));
      return { ok: true, channel: CHANNEL_ID };
    },
    sendMedia: async (ctx) => {
      const client = activeClients.get(ctx.to) || activeClients.get(`alicechat:backend:${ctx.accountId || 'default'}`);
      if (!client?.ws) throw new Error(`AliceChat target not connected: ${ctx.to}`);
      const mediaCandidates = [];
      if (ctx.mediaUrl) mediaCandidates.push(ctx.mediaUrl);
      if (Array.isArray(ctx.mediaUrls)) mediaCandidates.push(...ctx.mediaUrls);
      const attachments = mediaCandidates
        .map((mediaUrl) => toPushAttachmentRef(mediaUrl, ctx.audioAsVoice))
        .filter(Boolean);
      client.ws.send(JSON.stringify({
        type: 'push.message',
        text: String(ctx.text || ''),
        attachments,
        from: 'assistant',
        ts: Date.now(),
        providerId: String(client.cfg?.providerId || CHANNEL_ID),
        accountId: ctx.accountId || 'default',
      }));
      return { ok: true, channel: CHANNEL_ID };
    },
  },
  gateway: {
    startAccount: async (ctx: any, _account?: any) => {
      if (!ctx.account?.enabled) return waitUntilAbort(ctx.abortSignal);
      const key = String(ctx.accountId || 'default');
      const prev = activeServers.get(key);
      if (prev) {
        await prev.stop();
        activeServers.delete(key);
      }
      const server = createBridgeServer(ctx);
      activeServers.set(key, server);
      ctx.log?.info?.(`AliceChat bridge listening on ws://${ctx.account.websocketHost}:${ctx.account.websocketPort}`);
      return waitUntilAbort(ctx.abortSignal, async () => {
        const cur = activeServers.get(key);
        if (cur) {
          await cur.stop();
          activeServers.delete(key);
        }
      });
    },
    stopAccount: async (ctx) => {
      const key = String(ctx.accountId || 'default');
      const cur = activeServers.get(key);
      if (cur) {
        await cur.stop();
        activeServers.delete(key);
      }
    },
  },
};

export function register(api) {
  api.registerTool({
    name: 'music_action',
    label: 'Control music playback',
    description: 'Send a structured music action to AliceChat for playback control or AI playlist recommendations.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        type: {
          type: 'string',
          enum: [
            'play_track',
            'play_playlist',
            'queue_next',
            'queue_append',
            'pause_resume',
            'skip',
            'save_ai_playlist',
          ],
        },
        requestId: { type: 'string' },
        mode: {
          type: 'string',
          enum: ['pause', 'resume'],
          description: 'Optional for pause_resume. Omit to toggle.',
        },
        startIndex: { type: 'number', description: 'Optional start index for play_playlist.' },
        track: {
          type: 'object',
          additionalProperties: false,
          properties: {
            id: { type: 'string' },
            title: { type: 'string' },
            artist: { type: 'string' },
            album: { type: 'string' },
            category: { type: 'string' },
            description: { type: 'string' },
            artworkTone: { type: 'string', enum: MUSIC_ARTWORK_TONES },
            artworkUrl: { type: 'string' },
            preferredSourceId: { type: 'string' },
            sourceTrackId: { type: 'string' },
            durationMs: { type: 'number' },
          },
          required: ['title', 'artist'],
        },
        tracks: {
          type: 'array',
          items: {
            type: 'object',
            additionalProperties: false,
            properties: {
              id: { type: 'string' },
              title: { type: 'string' },
              artist: { type: 'string' },
              album: { type: 'string' },
              category: { type: 'string' },
              description: { type: 'string' },
              artworkTone: { type: 'string', enum: MUSIC_ARTWORK_TONES },
              artworkUrl: { type: 'string' },
              preferredSourceId: { type: 'string' },
              sourceTrackId: { type: 'string' },
              durationMs: { type: 'number' },
            },
            required: ['title', 'artist'],
          },
        },
        playlist: {
          type: 'object',
          additionalProperties: false,
          properties: {
            id: { type: 'string' },
            title: { type: 'string' },
            subtitle: { type: 'string' },
            tag: { type: 'string' },
            trackCount: { type: 'number' },
            artworkTone: { type: 'string', enum: MUSIC_ARTWORK_TONES },
            isAiGenerated: { type: 'boolean' },
          },
        },
        playlistDraft: {
          type: 'object',
          additionalProperties: false,
          properties: {
            id: { type: 'string' },
            title: { type: 'string' },
            subtitle: { type: 'string' },
            description: { type: 'string' },
            tag: { type: 'string' },
            artworkTone: { type: 'string', enum: MUSIC_ARTWORK_TONES },
            isAiGenerated: { type: 'boolean' },
            tracks: { type: 'array', items: { type: 'object' } },
          },
        },
        id: { type: 'string', description: 'Legacy draft id for save_ai_playlist.' },
        title: { type: 'string', description: 'Legacy draft title for save_ai_playlist.' },
        subtitle: { type: 'string', description: 'Legacy draft subtitle for save_ai_playlist.' },
        description: { type: 'string', description: 'Legacy draft description for save_ai_playlist.' },
        tag: { type: 'string', description: 'Legacy draft tag for save_ai_playlist.' },
        artworkTone: { type: 'string', enum: MUSIC_ARTWORK_TONES },
        isAiGenerated: { type: 'boolean', description: 'Legacy draft flag for save_ai_playlist.' },
      },
      required: ['type'],
    },
    async execute(_id, params) {
      try {
        const actionType = String(params.type || '').trim();
        const requestId = String(params.requestId || '').trim() || undefined;
        const playlistDraftInput = params.playlistDraft && typeof params.playlistDraft === 'object'
          ? params.playlistDraft
          : {
              id: params.id,
              title: params.title,
              subtitle: params.subtitle,
              description: params.description,
              tag: params.tag,
              artworkTone: params.artworkTone,
              isAiGenerated: params.isAiGenerated,
              tracks: params.tracks,
            };
        let payload = {};

        switch (actionType) {
          case 'play_track': {
            const normalizedTrack = normalizeMusicTrack(
              params.track,
              requestId || 'music-action:play-track',
              0,
              params.track?.artworkTone || 'aurora',
            );
            if (!normalizedTrack.title || !normalizedTrack.artist) {
              return {
                content: [{ type: 'text', text: 'Error: play_track 需要 track.title 和 track.artist。' }],
                details: { error: true },
              };
            }
            payload = {
              track: normalizedTrack,
              ...(normalizeMusicPlaylistRef(params.playlist, 1) ? { playlist: normalizeMusicPlaylistRef(params.playlist, 1) } : {}),
            };
            break;
          }
          case 'play_playlist': {
            const normalizedDraft = normalizeMusicPlaylistDraft(
              params.playlistDraft,
              requestId || 'music-action:play-playlist',
            );
            const normalizedPlaylist = normalizeMusicPlaylistRef(
              params.playlist || playlistDraftToPlaylistRef(normalizedDraft),
              normalizedDraft?.tracks?.length || 0,
            );
            if (!normalizedDraft && !normalizedPlaylist) {
              return {
                content: [{ type: 'text', text: 'Error: play_playlist 需要 playlist 或 playlistDraft。' }],
                details: { error: true },
              };
            }
            payload = {
              ...(normalizedPlaylist ? { playlist: normalizedPlaylist } : {}),
              ...(normalizedDraft ? { playlistDraft: normalizedDraft } : {}),
              ...(Number.isFinite(Number(params.startIndex)) ? { startIndex: Number(params.startIndex) } : {}),
            };
            break;
          }
          case 'queue_next':
          case 'queue_append': {
            const normalizedTracks = normalizeMusicTracks(
              params.tracks || (params.track ? [params.track] : []),
              requestId || `music-action:${actionType}`,
              params.artworkTone || 'aurora',
            );
            if (!normalizedTracks.length) {
              return {
                content: [{ type: 'text', text: `Error: ${actionType} 需要 track 或 tracks，且每首歌至少要有 title 和 artist。` }],
                details: { error: true },
              };
            }
            payload = {
              tracks: normalizedTracks,
              ...(normalizeMusicPlaylistRef(params.playlist, normalizedTracks.length)
                ? { playlist: normalizeMusicPlaylistRef(params.playlist, normalizedTracks.length) }
                : {}),
            };
            break;
          }
          case 'pause_resume':
            payload = {
              ...(String(params.mode || '').trim() ? { mode: String(params.mode || '').trim() } : {}),
            };
            break;
          case 'skip':
            payload = {};
            break;
          case 'save_ai_playlist': {
            const normalizedDraft = normalizeMusicPlaylistDraft(
              playlistDraftInput,
              requestId || params.id || `ai-playlist:${Date.now()}`,
            );
            if (!normalizedDraft || !normalizedDraft.title || !normalizedDraft.subtitle || !normalizedDraft.description) {
              return {
                content: [{ type: 'text', text: 'Error: save_ai_playlist 需要完整的 playlistDraft（至少 title/subtitle/description/tracks）。' }],
                details: { error: true },
              };
            }
            payload = normalizedDraft;
            break;
          }
          default:
            return {
              content: [{ type: 'text', text: `Error: 不支持的 music action: ${actionType}` }],
              details: { error: true },
            };
        }

        const response = await callAliceChatApi('POST', '/api/music/actions', {
          type: actionType,
          source: 'chatAi',
          ...(requestId ? { requestId } : {}),
          payload,
        });
        return {
          content: [{
            type: 'text',
            text: `Music action accepted: ${actionType}.`,
          }],
          details: response,
        };
      } catch (error) {
        return {
          content: [{ type: 'text', text: `Error: ${error?.message || String(error)}` }],
          details: { error: true },
        };
      }
    },
  });

  api.registerTool({
    name: 'save_latest_ai_playlist',
    label: 'Save latest AI playlist',
    description: 'Save the latest AI music playlist draft into AliceChat backend so the app hero card can refresh.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        id: { type: 'string', description: 'Playlist id. Recommended prefix: ai-playlist:...' },
        title: { type: 'string' },
        subtitle: { type: 'string' },
        description: { type: 'string' },
        tag: { type: 'string' },
        artworkTone: {
          type: 'string',
          enum: ['twilight', 'sunset', 'aurora', 'ocean', 'rose', 'midnight'],
        },
        isAiGenerated: { type: 'boolean' },
        tracks: {
          type: 'array',
          items: {
            type: 'object',
            additionalProperties: false,
            properties: {
              id: { type: 'string' },
              title: { type: 'string' },
              artist: { type: 'string' },
              album: { type: 'string' },
              category: { type: 'string' },
              description: { type: 'string' },
              artworkTone: {
                type: 'string',
                enum: ['twilight', 'sunset', 'aurora', 'ocean', 'rose', 'midnight'],
              },
              artworkUrl: { type: 'string' },
              preferredSourceId: { type: 'string' },
              sourceTrackId: { type: 'string' },
              durationMs: { type: 'number' },
            },
            required: ['title', 'artist'],
          },
        },
      },
      required: ['title', 'subtitle', 'description', 'tracks'],
    },
    async execute(_id, params) {
      try {
        const nowSeconds = Date.now() / 1000;
        const normalizedTracks = Array.isArray(params.tracks)
          ? params.tracks.map((track, index) => ({
              id: String(track.id || `${String(params.id || 'ai-playlist:latest')}:track:${index}`),
              title: String(track.title || '').trim(),
              artist: String(track.artist || '').trim(),
              album: String(track.album || '').trim(),
              category: String(track.category || '').trim(),
              description: String(track.description || '').trim(),
              artworkTone: String(track.artworkTone || params.artworkTone || 'aurora').trim() || 'aurora',
              artworkUrl: String(track.artworkUrl || '').trim() || undefined,
              preferredSourceId: String(track.preferredSourceId || '').trim() || undefined,
              sourceTrackId: String(track.sourceTrackId || '').trim() || undefined,
              durationMs: Number(track.durationMs || 0),
            })).filter((track) => track.title && track.artist)
          : [];

        if (!normalizedTracks.length) {
          return {
            content: [{ type: 'text', text: 'Error: tracks 不能为空，且每首歌至少要有 title 和 artist。' }],
            details: { error: true },
          };
        }

        const payload = {
          id: String(params.id || `ai-playlist:${Date.now()}`).trim(),
          title: String(params.title || '').trim(),
          subtitle: String(params.subtitle || '').trim(),
          description: String(params.description || '').trim(),
          tag: String(params.tag || 'AI').trim() || 'AI',
          artworkTone: String(params.artworkTone || 'aurora').trim() || 'aurora',
          isAiGenerated: params.isAiGenerated !== false,
          tracks: normalizedTracks,
          createdAt: nowSeconds,
          updatedAt: nowSeconds,
        };

        const response = await callAliceChatApi('POST', '/api/music/ai-playlists/latest', payload);
        return {
          content: [{
            type: 'text',
            text: `Saved latest AI playlist: ${payload.title} (${normalizedTracks.length} tracks).`,
          }],
          details: response,
        };
      } catch (error) {
        return {
          content: [{ type: 'text', text: `Error: ${error?.message || String(error)}` }],
          details: { error: true },
        };
      }
    },
  });

  api.registerTool({
    name: 'get_latest_ai_playlist',
    label: 'Get latest AI playlist',
    description: 'Read the latest AI music playlist draft from AliceChat backend.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {},
    },
    async execute() {
      try {
        const response = await callAliceChatApi('GET', '/api/music/ai-playlists/latest', {});
        const playlist = response?.playlist;
        if (!playlist) {
          return {
            content: [{ type: 'text', text: 'No latest AI playlist found.' }],
            details: response,
          };
        }
        const title = String(playlist.title || 'Untitled');
        const count = Array.isArray(playlist.tracks) ? playlist.tracks.length : 0;
        return {
          content: [{ type: 'text', text: `Latest AI playlist: ${title} (${count} tracks).` }],
          details: response,
        };
      } catch (error) {
        return {
          content: [{ type: 'text', text: `Error: ${error?.message || String(error)}` }],
          details: { error: true },
        };
      }
    },
  });

  api.registerChannel({ plugin: alicechatPlugin });
}

const plugin = {
  id: CHANNEL_ID,
  name: 'AliceChat Bridge',
  description: 'OpenClaw channel bridge for the AliceChat Python backend.',
  configSchema: {
    schema: {},
  },
  register(api) {
    register(api);
  },
};

export default plugin;
