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
  if (!String(mimeType).startsWith('image/')) return null;
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
  const raw = String(url || '').trim();
  const lower = raw.toLowerCase();
  if (audioAsVoice) return 'audio';
  if (lower.startsWith('data:image/')) return 'image';
  if (lower.startsWith('data:audio/')) return 'audio';
  if (lower.startsWith('data:video/')) return 'video';
  if (/\.(png|jpe?g|gif|webp|bmp|heic|heif|avif)(\?|$)/i.test(raw)) return 'image';
  if (/\.(mp3|wav|ogg|oga|m4a|aac|flac|opus|weba|wma)(\?|$)/i.test(raw)) return 'audio';
  if (/\.(mp4|mov|m4v|webm|mkv|avi|wmv|mpeg|mpg|3gp|ogv)(\?|$)/i.test(raw)) return 'video';
  return 'file';
}

function toPushAttachmentRef(mediaUrl, audioAsVoice) {
  const raw = String(mediaUrl || '').trim();
  if (!raw) return null;
  const inferredName = (() => {
    try {
      if (/^data:/i.test(raw)) return '';
      const parsed = /^file:/i.test(raw) || /^https?:/i.test(raw)
        ? new URL(raw).pathname
        : raw;
      return path.basename(decodeURIComponent(parsed.split('?', 1)[0] || '')).trim();
    } catch {
      return '';
    }
  })();
  const attachment = {
    type: classifyMedia(raw, audioAsVoice),
    audioAsVoice: !!audioAsVoice,
    ...(inferredName ? { name: inferredName, filename: inferredName } : {}),
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
  const normalizedMethod = String(method || 'GET').toUpperCase();
  const canSendBody = normalizedMethod !== 'GET' && normalizedMethod !== 'HEAD';
  const response = await fetch(url, {
    method: normalizedMethod,
    headers: {
      'content-type': 'application/json',
      'x-alicechat-password': appPassword,
    },
    body: canSendBody && payload !== undefined ? JSON.stringify(payload) : undefined,
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

const TODO_PRIORITIES = ['low', 'medium', 'high', 'urgent'];
const TODO_STATUSES = ['todo', 'doing', 'done', 'archived'];
const HABIT_FREQUENCIES = ['daily', 'weekly'];

function normalizeTodoPriority(value, fallback = 'medium') {
  const priority = String(value || '').trim().toLowerCase();
  return TODO_PRIORITIES.includes(priority) ? priority : fallback;
}

function normalizeTodoStatus(value, fallback = 'todo') {
  const status = String(value || '').trim().toLowerCase();
  return TODO_STATUSES.includes(status) ? status : fallback;
}

function normalizeTodoSubtasks(rawSubtasks, fallbackIdPrefix) {
  const subtasks = Array.isArray(rawSubtasks) ? rawSubtasks : [];
  return subtasks
    .map((item, index) => ({
      id: String(item?.id || `${String(fallbackIdPrefix || 'todo-action')}:subtask:${index}`),
      title: String(item?.title || '').trim(),
      isCompleted: item?.isCompleted === true,
    }))
    .filter((item) => item.title);
}

function getShanghaiNowParts() {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return {
    year: Number(values.year),
    month: Number(values.month),
    day: Number(values.day),
    hour: Number(values.hour),
    minute: Number(values.minute),
    second: Number(values.second),
  };
}

function shiftShanghaiDate(parts, days) {
  const shifted = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + days, 0, 0, 0));
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: shifted.getUTCDate(),
  };
}

function formatShanghaiIso(parts) {
  const pad = (value) => String(value).padStart(2, '0');
  return `${parts.year}-${pad(parts.month)}-${pad(parts.day)}T${pad(parts.hour)}:${pad(parts.minute)}:${pad(parts.second || 0)}+08:00`;
}

function parseChineseWeekday(text) {
  const match = text.match(/(?:周|星期|礼拜)([一二三四五六日天1-7])/);
  if (!match) return null;
  const map = {
    一: 1,
    二: 2,
    三: 3,
    四: 4,
    五: 5,
    六: 6,
    日: 7,
    天: 7,
  };
  return Number(map[match[1]] || match[1]);
}

function parseEnglishWeekday(text) {
  const match = text.match(/\b(next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i);
  if (!match) return null;
  const map = {
    monday: 1,
    tuesday: 2,
    wednesday: 3,
    thursday: 4,
    friday: 5,
    saturday: 6,
    sunday: 7,
  };
  return {
    weekday: map[match[2].toLowerCase()],
    next: !!match[1],
  };
}

function parseTodoTimeOfDay(text, fallback) {
  const colonMatch = text.match(/([01]?\d|2[0-3])[:：]([0-5]\d)/);
  if (colonMatch) {
    return { hour: Number(colonMatch[1]), minute: Number(colonMatch[2]), second: 0 };
  }
  const hourMatch = text.match(/([0-2]?\d)\s*(?:点|时)(半|[0-5]?\d分?)?/);
  if (hourMatch) {
    const suffix = hourMatch[2] || '';
    let hour = Number(hourMatch[1]);
    const minute = suffix === '半' ? 30 : Number(String(suffix).replace('分', '') || 0);
    if ((/下午|晚上|今晚|傍晚/.test(text)) && hour < 12) hour += 12;
    if (/中午/.test(text) && hour < 11) hour += 12;
    if (hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59) {
      return { hour, minute, second: 0 };
    }
  }
  if (/凌晨/.test(text)) return { hour: 1, minute: 0, second: 0 };
  if (/早上|上午|明早/.test(text)) return { hour: 9, minute: 0, second: 0 };
  if (/中午/.test(text)) return { hour: 12, minute: 0, second: 0 };
  if (/下午/.test(text)) return { hour: 15, minute: 0, second: 0 };
  if (/傍晚/.test(text)) return { hour: 18, minute: 0, second: 0 };
  if (/晚上|今晚/.test(text)) {
    return fallback.endOfDay
      ? { hour: 23, minute: 59, second: 59 }
      : { hour: 20, minute: 0, second: 0 };
  }
  if (/\btonight\b/i.test(text)) {
    return fallback.endOfDay
      ? { hour: 23, minute: 59, second: 59 }
      : { hour: 20, minute: 0, second: 0 };
  }
  if (/\bmorning\b/i.test(text)) return { hour: 9, minute: 0, second: 0 };
  if (/\bnoon\b/i.test(text)) return { hour: 12, minute: 0, second: 0 };
  if (/\bafternoon\b/i.test(text)) return { hour: 15, minute: 0, second: 0 };
  if (/\bevening|night\b/i.test(text)) return { hour: 20, minute: 0, second: 0 };
  return fallback.endOfDay
    ? { hour: 23, minute: 59, second: 59 }
    : { hour: 9, minute: 0, second: 0 };
}

function parseTodoRelativeDateText(rawText, options = {}) {
  const text = String(rawText || '').trim();
  if (!text) return null;
  const fallback = { endOfDay: (options as any).endOfDay !== false };
  const isoMatch = text.match(/(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2})[:：](\d{2})(?::(\d{2}))?)?/);
  if (isoMatch) {
    const time = isoMatch[4]
      ? { hour: Number(isoMatch[4]), minute: Number(isoMatch[5]), second: Number(isoMatch[6] || 0) }
      : parseTodoTimeOfDay(text, fallback);
    return formatShanghaiIso({
      year: Number(isoMatch[1]),
      month: Number(isoMatch[2]),
      day: Number(isoMatch[3]),
      ...time,
    });
  }

  const monthDayMatch = text.match(/(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?/);
  const now = getShanghaiNowParts();
  let date = { year: now.year, month: now.month, day: now.day };
  if (monthDayMatch) {
    date = {
      year: now.year,
      month: Number(monthDayMatch[1]),
      day: Number(monthDayMatch[2]),
    };
  } else if (/大后天/.test(text)) {
    date = shiftShanghaiDate(now, 3);
  } else if (/后天/.test(text)) {
    date = shiftShanghaiDate(now, 2);
  } else if (/明天|明日|明早|\btomorrow\b/i.test(text)) {
    date = shiftShanghaiDate(now, 1);
  } else if (/昨天|昨日|\byesterday\b/i.test(text)) {
    date = shiftShanghaiDate(now, -1);
  } else {
    const weekday = parseChineseWeekday(text);
    if (weekday) {
      const todayWeekday = new Date(Date.UTC(now.year, now.month - 1, now.day)).getUTCDay() || 7;
      let delta = weekday - todayWeekday;
      if (/下周|下星期|下礼拜/.test(text)) {
        delta += 7;
      } else if (!/本周|这周|这个星期|这星期|本星期|本礼拜/.test(text) && delta < 0) {
        delta += 7;
      }
      date = shiftShanghaiDate(now, delta);
    } else {
      const englishWeekday = parseEnglishWeekday(text);
      if (englishWeekday) {
        const todayWeekday = new Date(Date.UTC(now.year, now.month - 1, now.day)).getUTCDay() || 7;
        let delta = englishWeekday.weekday - todayWeekday;
        if (englishWeekday.next) {
          delta += 7;
        } else if (delta < 0) {
          delta += 7;
        }
        date = shiftShanghaiDate(now, delta);
      }
    }
  }

  return formatShanghaiIso({
    ...date,
    ...parseTodoTimeOfDay(text, fallback),
  });
}

function summarizeTodoSnapshot(snapshot, options = {}) {
  const source: any = snapshot || {};
  const opts: any = options || {};
  const projects = Array.isArray(source.projects) ? source.projects : [];
  const tasks = Array.isArray(source.tasks) ? source.tasks : [];
  const subtasks = Array.isArray(source.subtasks) ? source.subtasks : [];
  const includeArchived = opts.includeArchived === true;
  const limit = Number.isFinite(Number(opts.limit)) ? Math.max(1, Number(opts.limit)) : 50;
  const projectId = String(opts.projectId || '').trim();
  const scope = String(opts.scope || 'all').trim();
  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const endOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59, 999);
  const projectMap = new Map<string, any>(projects.map((project: any) => [String(project.id || ''), project]));

  let filteredTasks = tasks.filter((task) => {
    const project: any = projectMap.get(String(task.projectId || ''));
    if (!includeArchived && project?.archived) return false;
    if (projectId && String(task.projectId || '') !== projectId) return false;
    if (scope === 'completed') return task.status === 'done';
    if (scope === 'today') {
      if (task.status === 'done') return false;
      if (!task.dueAt) return false;
      const dueAt = new Date(task.dueAt);
      return dueAt >= startOfToday && dueAt <= endOfToday;
    }
    if (scope === 'upcoming') {
      if (task.status === 'done') return false;
      if (!task.dueAt) return false;
      return new Date(task.dueAt) > endOfToday;
    }
    if (scope === 'pending') {
      return task.status !== 'done' && task.status !== 'archived';
    }
    return true;
  });

  filteredTasks = filteredTasks.slice(0, limit);
  const taskIds = new Set(filteredTasks.map((task) => String(task.id || '')));
  const filteredSubtasks = subtasks.filter((subtask) => taskIds.has(String(subtask.taskId || '')));
  const lines = filteredTasks.map((task) => {
    const project: any = projectMap.get(String(task.projectId || ''));
    const dueLabel = task.dueAt ? ` due=${task.dueAt}` : '';
    const reminderLabel = task.reminderAt ? ` remind=${task.reminderAt}` : '';
    const subtaskLabel = Number(task.subtaskCount || 0) > 0
      ? ` subtasks=${Number(task.completedSubtaskCount || 0)}/${Number(task.subtaskCount || 0)}`
      : '';
    return `- [${String(task.status || 'todo')}] ${String(task.title || '')} (#${String(task.id || '')}) project=${String(project?.name || task.projectId || 'unknown')} priority=${String(task.priority || 'medium')}${dueLabel}${reminderLabel}${subtaskLabel}`;
  });

  return {
    projects,
    tasks: filteredTasks,
    subtasks: filteredSubtasks,
    summaryText: lines.length
      ? lines.join('\n')
      : `No todo tasks matched scope=${scope}.`,
  };
}

function normalizeHabitFrequency(value, fallback = 'daily') {
  const frequency = String(value || '').trim().toLowerCase();
  return HABIT_FREQUENCIES.includes(frequency) ? frequency : fallback;
}

function normalizeHabitWeekdays(rawWeekdays) {
  if (!Array.isArray(rawWeekdays)) return [];
  return [...new Set(
    rawWeekdays
      .map((day) => Number(day))
      .filter((day) => Number.isInteger(day) && day >= 1 && day <= 7),
  )].sort((a, b) => a - b);
}

function normalizeHabitReminderTime(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  const match = raw.match(/^(\d{1,2}):(\d{2})$/);
  if (!match) return raw;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return raw;
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

function summarizeHabitSnapshot(response, options = {}) {
  const opts: any = options || {};
  const habits = Array.isArray(response?.habits) ? response.habits : [];
  const scope = String(opts.scope || 'today').trim();
  const includeHistory = opts.includeHistory === true;
  const limit = Number.isFinite(Number(opts.limit)) ? Math.max(1, Number(opts.limit)) : 50;
  const today = new Date().toISOString().slice(0, 10);

  let filtered = habits.filter((habit) => {
    if (scope === 'all') return true;
    if (scope === 'active') return habit.active !== false;
    if (scope === 'inactive') return habit.active === false;
    if (scope === 'completed_today') return habit.dueToday === true && habit.todayInstance?.status === 'completed';
    if (scope === 'pending_today') return habit.dueToday === true && habit.todayInstance?.status !== 'completed';
    return habit.dueToday === true;
  });
  filtered = filtered.slice(0, limit);

  const weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];
  const lines = filtered.map((habit) => {
    const id = String(habit.id || '');
    const title = String(habit.title || '');
    const status = habit.todayInstance?.status || (habit.dueToday ? 'pending' : 'not_due');
    const frequency = String(habit.frequency || 'daily');
    const weekdays = normalizeHabitWeekdays(habit.weekdays)
      .map((day) => weekdayLabels[day - 1])
      .join('');
    const schedule = frequency === 'weekly' ? `weekly(${weekdays || 'none'})` : 'daily';
    const reminder = habit.reminderTime ? ` remind=${habit.reminderTime}` : '';
    const weekly = habit.stats?.weekly ? ` week=${habit.stats.weekly.done}/${habit.stats.weekly.total}` : '';
    const monthly = habit.stats?.monthly ? ` month=${habit.stats.monthly.done}/${habit.stats.monthly.total}` : '';
    return `- [${status}] ${title} (#${id}) ${schedule} streak=${Number(habit.streak || 0)}${weekly}${monthly}${reminder}`;
  });

  return {
    habits: includeHistory
      ? filtered
      : filtered.map((habit) => {
          const { history, ...rest } = habit || {};
          return rest;
        }),
    summaryText: lines.length
      ? lines.join('\n')
      : `No habits matched scope=${scope} for ${today}.`,
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

    const agentBodyText = text;

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
      video: { send: true, receive: true },
      documents: { send: true, receive: true },
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
    description: 'Control AliceChat music playback or save an AI playlist recommendation. Use save_ai_playlist for recommendations that should not start playback.',
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
    name: 'todo_action',
    label: 'Manage todo items',
    description: 'Create, update, complete, reopen, delete, or reorganize AliceChat todo items and projects. Read get_todo_snapshot first when editing an ambiguous existing item.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        type: {
          type: 'string',
          enum: [
            'create_task',
            'update_task',
            'complete_task',
            'reopen_task',
            'delete_task',
            'create_project',
            'update_project',
            'archive_project',
            'replace_subtasks',
          ],
        },
        requestId: { type: 'string' },
        taskId: { type: 'string' },
        projectId: { type: 'string' },
        projectName: { type: 'string' },
        title: { type: 'string' },
        name: { type: 'string', description: 'Project name for create_project/update_project.' },
        description: { type: 'string' },
        priority: { type: 'string', enum: TODO_PRIORITIES },
        status: { type: 'string', enum: TODO_STATUSES },
        dueAt: { type: 'string', description: 'ISO 8601 datetime with offset, for example 2026-05-27T23:59:59+08:00.' },
        reminderAt: { type: 'string', description: 'ISO 8601 datetime with offset, for example 2026-05-27T09:00:00+08:00.' },
        dueDateText: {
          type: 'string',
          description: 'Natural date/time text such as 明晚, 明天 10:00, 下周四, or tomorrow night. Resolved by the tool using Asia/Shanghai runtime time when dueAt is omitted.',
        },
        reminderDateText: {
          type: 'string',
          description: 'Natural reminder date/time text. Resolved by the tool using Asia/Shanghai runtime time when reminderAt is omitted.',
        },
        archived: { type: 'boolean' },
        subtasks: {
          type: 'array',
          items: {
            type: 'object',
            additionalProperties: false,
            properties: {
              id: { type: 'string' },
              title: { type: 'string' },
              isCompleted: { type: 'boolean' },
            },
            required: ['title'],
          },
        },
      },
      required: ['type'],
    },
    async execute(_id, params) {
      try {
        const input: any = params || {};
        const actionType = String(input.type || '').trim();
        const requestId = String(input.requestId || '').trim() || String(_id || '').trim() || undefined;
        const payload: any = {};

        if (String(input.taskId || '').trim()) payload.taskId = String(input.taskId).trim();
        if (String(input.projectId || '').trim()) payload.projectId = String(input.projectId).trim();
        if (String(input.projectName || '').trim()) payload.projectName = String(input.projectName).trim();
        if (String(input.title || '').trim()) payload.title = String(input.title).trim();
        if (String(input.name || '').trim()) payload.name = String(input.name).trim();
        if (input.description !== undefined) payload.description = String(input.description || '').trim();
        if (input.priority !== undefined) payload.priority = normalizeTodoPriority(input.priority);
        if (input.status !== undefined) payload.status = normalizeTodoStatus(input.status);
        if (input.dueAt !== undefined) {
          payload.dueAt = input.dueAt ? String(input.dueAt).trim() : null;
        } else if (input.dueDateText !== undefined) {
          payload.dueAt = parseTodoRelativeDateText(input.dueDateText, { endOfDay: true });
        }
        if (input.reminderAt !== undefined) {
          payload.reminderAt = input.reminderAt ? String(input.reminderAt).trim() : null;
        } else if (input.reminderDateText !== undefined) {
          payload.reminderAt = parseTodoRelativeDateText(input.reminderDateText, { endOfDay: false });
        }
        if (input.archived !== undefined) payload.archived = input.archived === true;
        if (input.subtasks !== undefined) {
          payload.subtasks = normalizeTodoSubtasks(
            input.subtasks,
            requestId || actionType || 'todo-action',
          );
        }

        if (actionType === 'create_task' && !payload.title) {
          return {
            content: [{ type: 'text', text: 'Error: create_task 需要 title。' }],
            details: { error: true },
          };
        }
        if (['update_task', 'complete_task', 'reopen_task', 'delete_task', 'replace_subtasks'].includes(actionType) && !payload.taskId) {
          return {
            content: [{ type: 'text', text: `Error: ${actionType} 需要 taskId。` }],
            details: { error: true },
          };
        }
        if (actionType === 'create_project' && !payload.name) {
          return {
            content: [{ type: 'text', text: 'Error: create_project 需要 name。' }],
            details: { error: true },
          };
        }
        if (['update_project', 'archive_project'].includes(actionType) && !payload.projectId && !payload.name) {
          return {
            content: [{ type: 'text', text: `Error: ${actionType} 至少需要 projectId 或 name。` }],
            details: { error: true },
          };
        }

        const response = await callAliceChatApi('POST', '/api/todo/actions', {
          type: actionType,
          source: 'chatAi',
          ...(requestId ? { requestId } : {}),
          payload,
        });
        return {
          content: [{
            type: 'text',
            text: `Todo action accepted: ${actionType}.`,
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
    name: 'get_todo_snapshot',
    label: 'Read todo snapshot',
    description: 'Read current AliceChat todo projects and tasks, optionally filtered by scope or project. Use before editing existing or ambiguous todo items.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        scope: {
          type: 'string',
          enum: ['all', 'pending', 'today', 'upcoming', 'completed'],
        },
        projectId: { type: 'string' },
        includeArchived: { type: 'boolean' },
        includeSubtasks: { type: 'boolean' },
        limit: { type: 'number' },
      },
    },
    async execute(_id, params) {
      try {
        const response = await callAliceChatApi('GET', '/api/todo', {});
        if (!response?.exists || !response?.snapshot) {
          return {
            content: [{ type: 'text', text: 'No todo snapshot found.' }],
            details: response,
          };
        }
        const summarized = summarizeTodoSnapshot(response.snapshot, params || {});
        const details = {
          ...response,
          snapshot: {
            projects: summarized.projects,
            tasks: summarized.tasks,
            ...(params?.includeSubtasks === true ? { subtasks: summarized.subtasks } : {}),
          },
        };
        return {
          content: [{
            type: 'text',
            text: summarized.summaryText,
          }],
          details,
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
    name: 'habit_action',
    label: 'Manage habits',
    description: 'Create, update, complete, reopen, toggle, delete, pause, resume, or refresh AliceChat habits. Read get_habit_snapshot first when editing an ambiguous existing habit.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        type: {
          type: 'string',
          enum: [
            'create_habit',
            'update_habit',
            'delete_habit',
            'complete_today',
            'reopen_today',
            'toggle_today',
            'refresh',
          ],
        },
        requestId: { type: 'string' },
        habitId: { type: 'string' },
        title: { type: 'string' },
        description: { type: 'string' },
        frequency: { type: 'string', enum: HABIT_FREQUENCIES },
        weekdays: {
          type: 'array',
          description: 'ISO weekdays for weekly habits: 1=Monday, 7=Sunday.',
          items: { type: 'number' },
        },
        reminderTime: { type: 'string', description: 'HH:mm local time, or empty string to clear.' },
        active: { type: 'boolean' },
        colorValue: { type: 'number' },
        iconCodePoint: { type: 'number' },
        sortOrder: { type: 'number' },
      },
      required: ['type'],
    },
    async execute(_id, params) {
      try {
        const input: any = params || {};
        const actionType = String(input.type || '').trim();
        const requestId = String(input.requestId || '').trim() || String(_id || '').trim() || undefined;
        const habitId = String(input.habitId || '').trim();
        const payload: any = {};

        if (input.title !== undefined) payload.title = String(input.title || '').trim();
        if (input.description !== undefined) payload.description = String(input.description || '').trim();
        if (input.frequency !== undefined) payload.frequency = normalizeHabitFrequency(input.frequency);
        if (input.weekdays !== undefined) payload.weekdays = normalizeHabitWeekdays(input.weekdays);
        if (input.reminderTime !== undefined) payload.reminderTime = normalizeHabitReminderTime(input.reminderTime);
        if (input.active !== undefined) payload.active = input.active === true;
        if (input.colorValue !== undefined) payload.colorValue = Number(input.colorValue || 0);
        if (input.iconCodePoint !== undefined) payload.iconCodePoint = Number(input.iconCodePoint || 0);
        if (input.sortOrder !== undefined) payload.sortOrder = Number(input.sortOrder || 0);

        if (actionType === 'create_habit') {
          if (!payload.title) {
            return {
              content: [{ type: 'text', text: 'Error: create_habit 需要 title。' }],
              details: { error: true },
            };
          }
          if (payload.frequency === 'weekly' && !payload.weekdays?.length) {
            return {
              content: [{ type: 'text', text: 'Error: weekly 习惯需要 weekdays，1=周一，7=周日。' }],
              details: { error: true },
            };
          }
          const response = await callAliceChatApi('POST', '/api/habits', payload);
          return {
            content: [{ type: 'text', text: `Habit created: ${String(response?.habit?.title || payload.title)}.` }],
            details: { ...response, requestId },
          };
        }

        if (actionType === 'update_habit') {
          if (!habitId) {
            return {
              content: [{ type: 'text', text: 'Error: update_habit 需要 habitId。' }],
              details: { error: true },
            };
          }
          if (payload.frequency === 'weekly' && input.weekdays !== undefined && !payload.weekdays?.length) {
            return {
              content: [{ type: 'text', text: 'Error: weekly 习惯至少需要一个 weekdays。' }],
              details: { error: true },
            };
          }
          const response = await callAliceChatApi('PUT', `/api/habits/${encodeURIComponent(habitId)}`, payload);
          return {
            content: [{ type: 'text', text: `Habit updated: ${String(response?.habit?.title || habitId)}.` }],
            details: { ...response, requestId },
          };
        }

        if (actionType === 'delete_habit') {
          if (!habitId) {
            return {
              content: [{ type: 'text', text: 'Error: delete_habit 需要 habitId。' }],
              details: { error: true },
            };
          }
          const response = await callAliceChatApi('DELETE', `/api/habits/${encodeURIComponent(habitId)}`, {});
          return {
            content: [{ type: 'text', text: `Habit deleted: ${habitId}.` }],
            details: { ...response, requestId },
          };
        }

        if (['complete_today', 'reopen_today', 'toggle_today'].includes(actionType)) {
          if (!habitId) {
            return {
              content: [{ type: 'text', text: `Error: ${actionType} 需要 habitId。` }],
              details: { error: true },
            };
          }
          if (actionType === 'toggle_today') {
            const response = await callAliceChatApi('POST', `/api/habits/${encodeURIComponent(habitId)}/toggle`, {});
            return {
              content: [{ type: 'text', text: `Habit toggled: ${String(response?.habit?.title || habitId)}.` }],
              details: { ...response, requestId },
            };
          }

          const snapshot = await callAliceChatApi('GET', '/api/habits', {});
          const habit = (Array.isArray(snapshot?.habits) ? snapshot.habits : [])
            .find((item) => String(item?.id || '') === habitId);
          if (!habit) {
            return {
              content: [{ type: 'text', text: `Error: habit not found: ${habitId}` }],
              details: { error: true, snapshot },
            };
          }
          const completed = habit.todayInstance?.status === 'completed';
          const shouldToggle = actionType === 'complete_today' ? !completed : completed;
          if (!shouldToggle) {
            return {
              content: [{ type: 'text', text: `Habit already ${completed ? 'completed' : 'open'} today: ${String(habit.title || habitId)}.` }],
              details: { ok: true, habit, unchanged: true, requestId },
            };
          }
          const response = await callAliceChatApi('POST', `/api/habits/${encodeURIComponent(habitId)}/toggle`, {});
          return {
            content: [{ type: 'text', text: `Habit ${actionType === 'complete_today' ? 'completed' : 'reopened'}: ${String(response?.habit?.title || habitId)}.` }],
            details: { ...response, requestId },
          };
        }

        if (actionType === 'refresh') {
          const response = await callAliceChatApi('POST', '/api/habits/refresh', {});
          return {
            content: [{ type: 'text', text: 'Habits refreshed.' }],
            details: { ...response, requestId },
          };
        }

        return {
          content: [{ type: 'text', text: `Error: unsupported habit action: ${actionType}` }],
          details: { error: true },
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
    name: 'get_habit_snapshot',
    label: 'Read habit snapshot',
    description: 'Read current AliceChat habits, optionally filtered by today, pending, completed, active, or inactive. Use before editing existing or ambiguous habits.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        scope: {
          type: 'string',
          enum: ['today', 'pending_today', 'completed_today', 'active', 'inactive', 'all'],
        },
        includeHistory: { type: 'boolean' },
        limit: { type: 'number' },
      },
    },
    async execute(_id, params) {
      try {
        const response = await callAliceChatApi('GET', '/api/habits', {});
        const summarized = summarizeHabitSnapshot(response, params || {});
        return {
          content: [{
            type: 'text',
            text: summarized.summaryText,
          }],
          details: {
            ...response,
            habits: summarized.habits,
          },
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
