import { WebSocketServer } from 'ws';
import fs from 'node:fs/promises';

const CHANNEL_ID = 'live2d';
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

function registerClient(accountId, client) {
  const keys = new Set([
    client.senderId,
    client.target,
    `live2d:backend:${accountId}`,
    `live2d:user:${client.senderId}`,
  ].filter(Boolean));
  for (const key of keys) activeClients.set(String(key), client);
  client._keys = [...keys];
}

function unregisterClient(client) {
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
  const port = Number(ctx.account.websocketPort || 18790);
  const host = String(ctx.account.websocketHost || '127.0.0.1');
  const channelRuntime = ctx.channelRuntime;
  if (!channelRuntime) throw new Error('channelRuntime unavailable; OpenClaw version too old');

  const wss = new WebSocketServer({ host, port });

  async function processChatRequest(ws, frame) {
    const requestId = String(frame.requestId || '');
    const text = String(frame.text || '');
    const requestedAgent = String(frame.agent || 'main').trim() || 'main';
    const requestedSession = String(frame.session || 'main').trim() || 'main';
    const senderId = String(frame.senderId || 'desktop-user');
    const senderName = String(frame.senderName || 'Live2D User');
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
      channel: 'Live2D',
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
      From: `live2d:user:${senderId}`,
      To: `live2d:backend:${accountId}`,
      SessionKey: sessionKey,
      AccountId: accountId,
      ChatType: 'direct',
      ConversationLabel: conversationLabel,
      SenderName: senderName,
      SenderId: senderId,
      Provider: CHANNEL_ID,
      Surface: CHANNEL_ID,
      MessageSid: requestId,
      OriginatingChannel: CHANNEL_ID,
      OriginatingTo: `live2d:backend:${accountId}`,
      AgentId: agentId,
    });

    const storePath = channelRuntime.session.resolveStorePath(currentCfg.session?.store, { agentId });
    await channelRuntime.session.recordInboundSession({
      storePath,
      sessionKey: inboundCtx.SessionKey ?? sessionKey,
      ctx: inboundCtx,
      onRecordError: (err) => ctx.log?.warn?.(`Failed updating session meta: ${String(err)}`),
    });

    let accumulated = '';
    const media = [];
    ws.send(JSON.stringify({ type: 'chat.accepted', requestId, sessionKey, agent: agentId }));

    await channelRuntime.reply.dispatchReplyWithBufferedBlockDispatcher({
      ctx: inboundCtx,
      cfg: currentCfg,
      dispatcherOptions: {
        onReplyStart: () => {
          ws.send(JSON.stringify({ type: 'chat.typing', requestId }));
        },
        deliver: async (payload) => {
          const nextText = String(payload?.text ?? payload?.body ?? '');
          if (nextText) {
            const delta = nextText.startsWith(accumulated) ? nextText.slice(accumulated.length) : nextText;
            accumulated = nextText;
            if (delta) {
              ws.send(JSON.stringify({ type: 'chat.delta', requestId, delta, reply: accumulated }));
            }
          }
          if (payload?.mediaUrl) {
            const item = {
              url: payload.mediaUrl,
              type: classifyMedia(payload.mediaUrl, payload.audioAsVoice),
              audioAsVoice: !!payload.audioAsVoice,
            };
            media.push(item);
            ws.send(JSON.stringify({ type: 'chat.media', requestId, media: item }));
          }
        },
      },
      replyOptions: {
        images,
      },
    });

    ws.send(JSON.stringify({
      type: 'chat.final',
      requestId,
      reply: accumulated,
      media,
      state: 'final',
      sessionKey,
      agent: agentId,
    }));
  }

  wss.on('connection', (ws, req) => {
    const remoteAddress = req.socket.remoteAddress || '未知IP';
    try {
      const url = new URL(`http://${req.headers.host || 'localhost'}${req.url || ''}`);
      const token = url.searchParams.get('token');

      if (!token || token.length < 32 || token !== process.env.LIVE2D_SECRET) {
        console.error(`[Live2D Security] Unauthorized connection attempt from ${req.socket.remoteAddress}`);
        ws.close(1008, 'Authentication failed');
        return;                    // 直接关闭连接，不继续注册事件
      }

      console.log(`[Live2D] Python backend authenticated successfully from ${req.socket.remoteAddress}`);
    } catch (err) {
      console.error(`[Live2D] Invalid connection request from ${req.socket.remoteAddress}`);
      ws.close(1008, 'Invalid request');
      return;
    }  
    let client : any = null;
    ws.on('close', () => {
    if (client) {
      unregisterClient(client);
    }
  });
    // 消息处理
  ws.on('message', async (raw) => {
    let frame: any;

    try {
      frame = JSON.parse(String(raw));
    } catch (err) {
      console.warn(`[Live2D] 收到无效 JSON 来自 ${remoteAddress}`);
      ws.send(JSON.stringify({ type: 'chat.error', error: 'invalid_json' }));
      return;
    }

    try {
      switch (frame.type) {
        case 'bridge.register':
          client = {
            ws,
            accountId: String(ctx.accountId || 'default'),
            senderId: String(frame.senderId || 'desktop-user'),
            senderName: String(frame.senderName || 'Live2D User'),
            target: String(frame.target || frame.senderId || 'desktop-user'),
          };

          registerClient(String(ctx.accountId || 'default'), client);

          ws.send(JSON.stringify({
            type: 'bridge.registered',
            target: client.target,
            senderId: client.senderId,
          }));
          break;

        case 'chat.request':
          await processChatRequest(ws, frame);
          break;

        case 'ping':
          ws.send(JSON.stringify({ 
            type: 'pong', 
            ts: Date.now() 
          }));
          break;

        default:
          ws.send(JSON.stringify({
            type: 'chat.error',
            requestId: frame?.requestId,
            error: 'unsupported_frame_type',
          }));
      }
    } catch (error: any) {
      console.error(`[Live2D] 处理消息时发生错误 来自 ${remoteAddress}：`, error);

      ws.send(JSON.stringify({
        type: 'chat.error',
        requestId: frame?.requestId,
        error: error?.message || 'bridge_error',
      }));
    }
  });

  // 可选：监听 WebSocket 错误
  ws.on('error', (err) => {
    console.error(`[Live2D] WebSocket 错误 来自 ${remoteAddress}：`, err);
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

const live2dPlugin = {
  id: CHANNEL_ID,
  meta: {
    id: CHANNEL_ID,
    label: 'Live2D',
    selectionLabel: 'Live2D Bridge',
    blurb: 'Bridge channel between OpenClaw and the Live2D Python backend.',
    order: 95,
    docsPath: '/channels/live2d',
    aliases: ['live2d'],
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
    listAccountIds: (cfg) => (cfg.channels?.live2d?.enabled ? ['default'] : []),
    resolveAccount: (cfg, accountId) => ({
      accountId: accountId || 'default',
      enabled: !!cfg.channels?.live2d?.enabled,
      websocketHost: cfg.channels?.live2d?.websocketHost || '127.0.0.1',
      websocketPort: Number(cfg.channels?.live2d?.websocketPort || 18790),
    }),
    inspectAccount: (cfg, accountId) => ({
      accountId: accountId || 'default',
      enabled: !!cfg.channels?.live2d?.enabled,
      websocketHost: cfg.channels?.live2d?.websocketHost || '127.0.0.1',
      websocketPort: Number(cfg.channels?.live2d?.websocketPort || 18790),
    }),
  },
  configSchema: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        enabled: { type: 'boolean', default: false },
        websocketHost: { type: 'string', default: '127.0.0.1' },
        websocketPort: { type: 'number', default: 18790 },
      },
    },
    uiHints: {
      enabled: { label: '启用 Live2D channel bridge' },
      websocketHost: { label: 'WebSocket 主机', placeholder: '127.0.0.1' },
      websocketPort: { label: 'WebSocket 端口', placeholder: '18790' },
    },
  },
  messaging: {
    normalizeTarget: (raw) => String(raw || '').trim() || undefined,
    targetResolver: {
      hint: 'Use desktop-user or live2d:backend:default for the connected Live2D client.',
      looksLikeId: (raw, normalized) => Boolean((normalized || raw || '').trim()),
    },
  },
  outbound: {
    deliveryMode: 'direct',
    resolveTarget: ({ to, accountId }) => {
      const target = String(to || '').trim();
      if (!target) return { ok: false, error: new Error('Live2D target is required') };
      const resolved = activeClients.get(target) || activeClients.get(`live2d:backend:${accountId || 'default'}`);
      if (!resolved) return { ok: false, error: new Error(`Unknown target "${target}" for Live2D.`) };
      return { ok: true, to: target };
    },
    sendText: async (ctx) => {
      const client = activeClients.get(ctx.to) || activeClients.get(`live2d:backend:${ctx.accountId || 'default'}`);
      if (!client?.ws) throw new Error(`Live2D target not connected: ${ctx.to}`);
      client.ws.send(JSON.stringify({
        type: 'push.message',
        role: 'assistant',
        text: String(ctx.text || ''),
        meta: ctx.identity?.name || 'OpenClaw Agent',
        attachments: [],
      }));
      return { ok: true, channel: CHANNEL_ID };
    },
    sendMedia: async (ctx) => {
      const client = activeClients.get(ctx.to) || activeClients.get(`live2d:backend:${ctx.accountId || 'default'}`);
      if (!client?.ws) throw new Error(`Live2D target not connected: ${ctx.to}`);
      const attachment = await mediaUrlToDataPayload(ctx.mediaUrl);
      const payload = {
        type: 'push.message',
        role: 'assistant',
        text: String(ctx.text || ''),
        meta: ctx.identity?.name || 'OpenClaw Agent',
        attachments: attachment ? [{ kind: classifyMedia(ctx.mediaUrl, false), mimeType: attachment.mimeType, data: attachment.data }] : [],
      };
      ctx.deps?.log?.info?.(`Live2D push media: to=${ctx.to} mediaUrl=${String(ctx.mediaUrl || '')} hasAttachment=${Boolean(attachment)} textLen=${payload.text.length}`);
      client.ws.send(JSON.stringify(payload));
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
      ctx.log?.info?.(`Live2D bridge listening on ws://${ctx.account.websocketHost}:${ctx.account.websocketPort}`);
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

const plugin = {
  id: CHANNEL_ID,
  name: 'Live2D Bridge',
  description: 'OpenClaw channel bridge for the Live2D Python backend.',
  configSchema: {
    schema: {},
  },
  register(api) {
    api.registerChannel({ plugin: live2dPlugin });
  },
};

export default plugin;
