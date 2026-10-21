import { WebSocket, WebSocketServer } from 'ws';
import type { Server } from 'node:http';
import type { Store } from '../store/db.js';
import { message, parseMessage, validPayload, type Message } from './messages.js';

type Client = { ws: WebSocket; room: string; id: string; hello: boolean; online: boolean; lastStateAt: number; broadcastAt: number; state: any; countdown: number | null };
export function createHub(server: Server, store: Store, authorize: (code: string, ip: string) => any,
  options: { now: () => number; offlineMs: number; ackMs: number; tickMs: number }) {
  let closing = false;
  const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
  const clients = new Map<string, Client>();
  const controls = new Map<WebSocket, string>();
  const pongs = new Map<WebSocket, number>();
  const pending = new Map<string, { client: Client; timer: ReturnType<typeof setTimeout> }>();
  const send = (ws: WebSocket, m: Message) => { if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(m)); };
  const broadcast = (room: string, m: Message) => { for (const [ws, r] of controls) if (r === room) send(ws, m); };
  const ack = (room: string, clientId: string, refId: string, ok: boolean, error?: string) => broadcast(room, message('ack', { refId, ok, ...(error ? { error } : {}) }, clientId));
  const snapshot = (room: string) => message('room', {
    room: store.room(room), clients: store.clients(room).map(c => {
      const live = clients.get(c.clientId);
      return live?.room === room ? { ...c, online: live.online, lastState: live.state, countdown: live.countdown } : c;
    }), recordings: store.recordings(room), log: store.logs(room),
  });
  const refresh = (room: string) => broadcast(room, snapshot(room));
  const log = (room: string, client: string | null, actor: string, level: string, code: string, text: string, detail?: unknown) =>
    broadcast(room, message('log', store.log(room, client, actor, level, code, text, detail)));
  const offline = (c: Client) => {
    if (!c.online) return;
    c.online = false; c.countdown = null;
    broadcast(c.room, message('client_offline', { clientId: c.id }));
    refresh(c.room);
  };
  const forward = (c: Client, m: Message) => {
    const key = `${c.room}:${m.id}`;
    const waiting = pending.get(key);
    if (waiting?.client === c) return;
    if (waiting) clearTimeout(waiting.timer);
    const timer = setTimeout(() => { pending.delete(key); ack(c.room, c.id, m.id, false, 'ACK_TIMEOUT'); }, options.ackMs);
    pending.set(key, { client: c, timer });
    send(c.ws, m);
  };
  const receiveClient = (c: Client, m: Message) => {
    const p = m.payload;
    if (!['hello', 'state', 'countdown', 'recording_started', 'recording_stopped', 'event', 'ack'].includes(m.type)) return;
    if (!validPayload(m)) { c.ws.close(1008, 'INVALID_PAYLOAD'); return; }
    if (m.type === 'hello') {
      const previous = store.db.prepare('SELECT session_id FROM clients WHERE id=?').get(c.id) as any;
      store.db.prepare(`INSERT INTO clients VALUES (?,?,?,?,?,?,?,NULL) ON CONFLICT(id) DO UPDATE SET
        pending_command=CASE WHEN clients.session_id=excluded.session_id THEN clients.pending_command ELSE NULL END,
        session_id=excluded.session_id,name=excluded.name,os_json=excluded.os_json,app_version=excluded.app_version,last_seen=excluded.last_seen`).run(
        c.id, c.room, p.name, JSON.stringify(p.os), p.appVersion, options.now(), options.now());
      c.hello = true;
      if (previous && previous.session_id !== c.room) refresh(previous.session_id);
      const row = store.db.prepare('SELECT pending_command FROM clients WHERE id=?').get(c.id) as any;
      if (row.pending_command) forward(c, JSON.parse(row.pending_command));
      refresh(c.room);
      return;
    }
    if (!c.hello) { c.ws.close(1008, 'HELLO_REQUIRED'); return; }
    if (m.type === 'state') {
      c.state = p; c.lastStateAt = options.now();
      if (p.status !== 'countdown') c.countdown = null;
      store.db.prepare('UPDATE clients SET last_seen=? WHERE id=?').run(options.now(), c.id);
      if (!c.online) {
        c.online = true;
        const row = store.db.prepare('SELECT pending_command FROM clients WHERE id=?').get(c.id) as any;
        if (row?.pending_command) forward(c, JSON.parse(row.pending_command));
        broadcast(c.room, message('client_online', { clientId: c.id })); refresh(c.room);
      }
      if (options.now() - c.broadcastAt >= 1000) { c.broadcastAt = options.now(); broadcast(c.room, message('client_state', { clientId: c.id, state: p })); }
      return;
    }
    if (m.type === 'ack') {
      const key = `${c.room}:${p.refId}`;
      const waiting = pending.get(key);
      if (waiting?.client !== c) return;
      clearTimeout(waiting.timer); pending.delete(key);
      const row = store.db.prepare('SELECT pending_command FROM clients WHERE id=?').get(c.id) as any;
      if (row?.pending_command && JSON.parse(row.pending_command).id === p.refId && p.ok)
        store.db.prepare('UPDATE clients SET pending_command=NULL WHERE id=?').run(c.id);
    }
    if (m.type === 'countdown') c.countdown = p.secondsLeft;
    if (m.type === 'recording_started') {
      const existing = store.db.prepare('SELECT session_id,client_id FROM recordings WHERE id=?').get(p.recordingId) as any;
      if (existing && (existing.session_id !== c.room || existing.client_id !== c.id)) { c.ws.close(1008, 'RECORDING_CONFLICT'); return; }
      store.db.prepare('INSERT OR IGNORE INTO recordings VALUES (?,?,?,?,NULL,?,NULL)').run(p.recordingId, c.room, c.id, p.startedAt, JSON.stringify(p.tracks));
      c.countdown = null;
      c.state = { ...c.state, status: 'recording', recordingId: p.recordingId, elapsedMs: 0 };
      log(c.room, c.id, '客户端', 'info', m.type, '录制已开始', p);
    }
    if (m.type === 'recording_stopped') {
      store.db.prepare('UPDATE recordings SET stopped_at=?,files_json=? WHERE id=? AND session_id=? AND client_id=?').run(p.stoppedAt, JSON.stringify(p.files), p.recordingId, c.room, c.id);
      c.countdown = null; c.state = { ...c.state, status: 'ready', elapsedMs: 0 };
      log(c.room, c.id, '客户端', 'info', m.type, '录制已停止', p);
    }
    if (m.type === 'event') log(c.room, c.id, '客户端', p.level, p.code, p.message, p.detail);
    broadcast(c.room, { ...m, clientId: c.id });
    if (m.type === 'recording_started' || m.type === 'recording_stopped') refresh(c.room);
  };
  const receiveControl = (ws: WebSocket, room: string, m: Message) => {
    if (!['start', 'stop'].includes(m.type)) return;
    const reject = (error: string) => send(ws, message('ack', { refId: m.id, ok: false, error }, m.clientId));
    if (!validPayload(m) || !m.clientId || typeof m.operator !== 'string' || !m.operator.trim() || m.operator.length > 80) return reject('INVALID_COMMAND');
    const r = store.room(room);
    if (r.archivedAt || r.expiresAt <= options.now()) return reject('ROOM_INACTIVE');
    const row = store.db.prepare('SELECT * FROM clients WHERE id=? AND session_id=?').get(m.clientId, room);
    if (!row) return reject('CLIENT_NOT_FOUND');
    const command = { ...m, operator: m.operator.trim() };
    log(room, m.clientId, command.operator, 'info', m.type, m.type === 'start' ? '开始录制' : '停止录制', { refId: m.id });
    const c = clients.get(m.clientId);
    if (!c?.online || c.room !== room || c.ws.readyState !== WebSocket.OPEN) {
      if (m.type === 'start') return reject('CLIENT_OFFLINE');
      store.db.prepare('UPDATE clients SET pending_command=? WHERE id=?').run(JSON.stringify(command), m.clientId);
      return send(ws, message('ack', { refId: m.id, ok: true, queued: true }, m.clientId));
    }
    if (m.type === 'start' && c.state?.status !== 'ready') return reject('CLIENT_NOT_READY');
    forward(c, command);
  };
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const fail = (status: number, error: string) => {
      const body = JSON.stringify({ error });
      socket.end(`HTTP/1.1 ${status} Rejected\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`);
    };
    if (!['/ws/client', '/ws/control'].includes(url.pathname)) return fail(404, 'NOT_FOUND');
    const isClient = url.pathname === '/ws/client';
    const room = isClient ? authorize(url.searchParams.get('code') ?? '', req.socket.remoteAddress ?? '') : store.room(url.searchParams.get('room') ?? '');
    if (!room) return fail(403, isClient ? 'INVALID_CODE' : 'ROOM_NOT_FOUND');
    const id = url.searchParams.get('client') ?? '';
    if (isClient && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return fail(400, 'INVALID_CLIENT');
    wss.handleUpgrade(req, socket, head, ws => {
      pongs.set(ws, options.now());
      ws.on('pong', () => pongs.set(ws, options.now()));
      ws.on('error', () => ws.terminate());
      let c: Client | undefined;
      if (isClient) {
        const previous = clients.get(id);
        if (previous) { offline(previous); previous.ws.close(4001, 'REPLACED'); }
        c = { ws, room: room.id, id, hello: false, online: false, state: null, countdown: null, lastStateAt: options.now(), broadcastAt: -Infinity };
        clients.set(id, c);
      } else { controls.set(ws, room.id); send(ws, snapshot(room.id)); }
      ws.on('message', (data, binary) => {
        if (c && clients.get(id) !== c) return;
        const m = !binary && parseMessage(data.toString(), isClient ? 'client' : 'control');
        if (!m) { ws.close(1008, 'INVALID_MESSAGE'); return; }
        try { if (c) receiveClient(c, m); else receiveControl(ws, room.id, m); }
        catch (error) { console.error(error); ws.close(1011, 'SERVER_ERROR'); }
      });
      ws.on('close', () => {
        pongs.delete(ws); controls.delete(ws);
        if (closing) return;
        if (c && clients.get(id) === c) { offline(c); clients.delete(id); }
      });
    });
  });
  const tick = setInterval(() => {
    for (const c of clients.values()) if (options.now() - c.lastStateAt >= options.offlineMs) offline(c);
  }, options.tickMs);
  const ping = setInterval(() => {
    for (const [ws, last] of pongs) { if (options.now() - last >= 20000) ws.terminate(); else ws.ping(); }
  }, 10000);
  return { refresh, close() {
    closing = true; clearInterval(tick); clearInterval(ping);
    for (const p of pending.values()) clearTimeout(p.timer);
    for (const ws of pongs.keys()) ws.terminate();
    wss.close();
  } };
}
