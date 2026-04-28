import { WebSocketServer } from 'ws';
import fsSync from 'node:fs';
import path from 'node:path';
import fs from 'node:fs/promises';
import { createChannelReplyPipeline } from 'openclaw/plugin-sdk/channel-reply-pipeline';

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
      frameType: String(frame?.type || meta.frameType || ''),
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

function waitUntilAbort(signal, onAbort) {
  return new Promise((resolve) => {
    if (signal.aborted) {
      Promise.resolve(onAbort?.()).finally(resolve);
      return;
    }
    signal.addEventListener(
      'abort',
      () => {
        Promise.resolve(onAbort?.()).finally(resolve);
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

function classifyMedia(url, audioAsVoice) {
  if (audioAsVoice) return 'audio';
  if (/\.(mp3|wav|ogg|m4a|aac|webm)(\?|$)/i.test(String(url || ''))) return 'audio';
  return 'image';
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

async function mediaUrlToDataPayload(mediaUrl) {
  if (!mediaUrl) return null;
  const raw = String(mediaUrl).trim();
  if (/^data:/i.test(raw)) {
    const match = /^data:([^;]+);base64,(.*)$/i.exec(raw);
    if (!match) return null;
    return { mimeType: match[1], data: match[2] };
  }
  const resolveMimeType = (pathname) => {
    const ext = String(pathname || '').split('.').pop()?.toLowerCase() || '';
    return ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg'
      : ext === 'webp' ? 'image/webp'
      : ext === 'gif' ? 'image/gif'
      : ext === 'mp3' ? 'audio/mpeg'
      : ext === 'wav' ? 'audio/wav'
      : ext === 'ogg' ? 'audio/ogg'
      : ext === 'm4a' ? 'audio/mp4'
      : ext === 'webm' ? 'audio/webm'
      : 'image/png';
  };
  if (/^file:/i.test(raw)) {
    const url = new URL(raw);
    const buffer = await fs.readFile(url);
    return { mimeType: resolveMimeType(url.pathname), data: buffer.toString('base64') };
  }
  if (raw.startsWith('/')) {
    const buffer = await fs.readFile(raw);
    return { mimeType: resolveMimeType(raw), data: buffer.toString('base64') };
  }
  return null;
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
    const images = attachments.map(toReplyImage).filter(Boolean);

    const currentCfg = ctx.cfg;
    const route = channelRuntime.routing.resolveAgentRoute({
      cfg: currentCfg,
      channel: CHANNEL_ID,
      accountId,
      peer: { kind: 'direct', id: senderId },
    });
    const agentId = requestedAgent || route.agentId;

    const body = channelRuntime.reply.formatAgentEnvelope({
      channel: channelLabel,
      from: senderName,
      timestamp: Date.now(),
      envelope: channelRuntime.reply.resolveEnvelopeFormatOptions(currentCfg),
      body: text,
    });

    const inboundCtx = channelRuntime.reply.finalizeInboundContext({
      Body: body,
      BodyForAgent: text,
      RawBody: text,
      CommandBody: text,
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
    });

    const storePath = channelRuntime.session.resolveStorePath(currentCfg.session?.store, { agentId });
    await channelRuntime.session.recordInboundSession({
      storePath,
      sessionKey: inboundCtx.SessionKey ?? sessionKey,
      ctx: inboundCtx,
      onRecordError: (err) => ctx.log?.warn?.(`Failed updating session meta: ${String(err)}`),
    });

    let frameSeq = 0;
    let terminalSent = false;
    let accumulatedReply = '';
    const finalMedia = [];
    const sendBridgeFrame = (outFrame, phase) => {
      if (terminalSent) {
        throw new Error(`attempted to send frame after terminal state: ${outFrame?.type || 'unknown'}`);
      }
      const frameWithSeq = {
        ...outFrame,
        seq: ++frameSeq,
      };
      if (outFrame?.type === 'chat.final' || outFrame?.type === 'chat.error') {
        terminalSent = true;
      }
      auditFrame('gateway_backend_ws', 'gateway->backend', frameWithSeq, {
        phase,
        accountId,
        requestId,
        sessionKey,
        agent: agentId,
      });
      ws.send(JSON.stringify(frameWithSeq));
    };

    sendBridgeFrame({ type: 'chat.accepted', requestId, sessionKey, agent: agentId }, 'gateway_send_chat_accepted');

    const { onModelSelected, ...replyPipeline } = createChannelReplyPipeline({
      cfg: currentCfg,
      agentId,
      channel: CHANNEL_ID,
      accountId,
    });

    await channelRuntime.reply.dispatchReplyWithBufferedBlockDispatcher({
      ctx: inboundCtx,
      cfg: currentCfg,
      dispatcherOptions: {
        ...replyPipeline,
        onReplyStart: () => {
          sendBridgeFrame({ type: 'chat.typing', requestId }, 'gateway_send_chat_typing');
        },
        deliver: async (payload, info) => {
          const text = String(payload?.text ?? payload?.body ?? '').trim();
          const payloadKind = String(info?.kind || payload?.kind || 'block');
          const lower = text.toLowerCase();
          const classifyToolKind = () => {
            if (/(web_search|web search|web_fetch|web fetch|search|搜索|查一下|查一查|lookup|google|bing)/i.test(text)) return 'search';
            if (/(read\(|\bread\b|\bcat\b|\bsed\b|\btail\b|\bhead\b|\bgrep\b|查看文件|读取|读一下|翻文件|inspect|open file)/i.test(text)) return 'read';
            if (/(exec\(|\bexec\b|bash|shell|command|命令|运行|python3|\bgit\b|\bnpm\b|\bpnpm\b|\bflutter\b|\bpytest\b|\bmake\b)/i.test(text)) return 'exec';
            return 'tool';
          };

          if (text) {
            if (payloadKind === 'tool') {
              sendBridgeFrame({
                type: 'chat.progress',
                requestId,
                stage: 'tool',
                kind: classifyToolKind(),
                text,
              }, 'gateway_send_chat_progress');
            } else if (payloadKind === 'block' || payloadKind === 'final') {
              const delta = text.startsWith(accumulatedReply) ? text.slice(accumulatedReply.length) : text;
              accumulatedReply = text;
              sendBridgeFrame({
                type: 'chat.delta',
                requestId,
                kind: payloadKind,
                delta,
                reply: accumulatedReply,
              }, 'gateway_send_chat_delta');
            } else if (lower) {
              sendBridgeFrame({
                type: 'chat.progress',
                requestId,
                stage: payloadKind,
                kind: classifyToolKind(),
                text,
              }, 'gateway_send_chat_progress');
            }
          }

          const mediaUrls = Array.isArray(payload?.mediaUrls)
            ? payload.mediaUrls
            : payload?.mediaUrl
              ? [payload.mediaUrl]
              : [];
          for (const mediaUrl of mediaUrls) {
            if (!mediaUrl) continue;
            const item = {
              url: mediaUrl,
              type: classifyMedia(mediaUrl, payload.audioAsVoice),
              audioAsVoice: !!payload.audioAsVoice,
            };
            finalMedia.push(item);
            sendBridgeFrame({ type: 'chat.media', requestId, media: item }, 'gateway_send_chat_media');
          }
        },
      },
      replyOptions: {
        images,
        onModelSelected,
      },
    });

    sendBridgeFrame({
      type: 'chat.final',
      requestId,
      reply: accumulatedReply,
      media: finalMedia,
      state: 'final',
      finishReason: 'completed',
      sessionKey,
      agent: agentId,
    }, 'gateway_send_chat_final');
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
      await new Promise((resolve, reject) => {
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
      }));
      return { ok: true, channel: CHANNEL_ID };
    },
    sendMedia: async (ctx) => {
      const client = activeClients.get(ctx.to) || activeClients.get(`alicechat:backend:${ctx.accountId || 'default'}`);
      if (!client?.ws) throw new Error(`AliceChat target not connected: ${ctx.to}`);
      const mediaCandidates = [];
      if (ctx.mediaUrl) mediaCandidates.push(ctx.mediaUrl);
      if (Array.isArray(ctx.mediaUrls)) mediaCandidates.push(...ctx.mediaUrls);
      const attachments = [];
      for (const mediaUrl of mediaCandidates) {
        const payload = await mediaUrlToDataPayload(mediaUrl);
        if (!payload) continue;
        attachments.push({
          type: classifyMedia(mediaUrl, ctx.audioAsVoice),
          mimeType: payload.mimeType,
          content: payload.data,
          audioAsVoice: !!ctx.audioAsVoice,
        });
      }
      client.ws.send(JSON.stringify({
        type: 'push.message',
        text: String(ctx.text || ''),
        attachments,
        from: 'assistant',
        ts: Date.now(),
      }));
      return { ok: true, channel: CHANNEL_ID };
    },
  },
  gateway: {
    startAccount: async (ctx) => {
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
    api.registerChannel({ plugin: alicechatPlugin });
  },
};

export default plugin;
