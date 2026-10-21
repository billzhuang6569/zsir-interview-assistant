import { WebSocket } from 'ws';
import { randomUUID } from 'node:crypto';
import { ulid } from 'ulid';
const [code, base = 'ws://127.0.0.1:8080', clientId = randomUUID()] = process.argv.slice(2);
if (!/^\d{6}$/.test(code ?? '')) throw new Error('Usage: npm run mock -- <code> [ws://host:8080] [client-uuid]');
const url = new URL('/ws/client', base); url.searchParams.set('code', code); url.searchParams.set('client', clientId);
let socket: WebSocket;
let status = 'ready', recordingId = '', startedAt = 0, tracks = ['cam', 'screen'];
let countdown: ReturnType<typeof setInterval> | undefined;
let reconnect: ReturnType<typeof setTimeout> | undefined;
let exiting = false;
const handled = new Set<string>();
const send = (type: string, payload: unknown) => { if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type, id: ulid(), ts: Date.now(), from: 'client', payload })); };
const state = () => send('state', { status, recordingId, elapsedMs: status === 'recording' ? Date.now() - startedAt : 0,
  tracks: Object.fromEntries(['cam', 'screen'].map(t => [t, { enabled: tracks.includes(t), ok: true }])), disk: { freeBytes: 335000000000 }, warnings: [] });
function connect() {
  socket = new WebSocket(url);
  socket.on('open', () => {
    console.log(`Mock joined: ${clientId}`);
    send('hello', { name: '模拟嘉宾', os: { platform: 'mock', version: '1', arch: 'mock' }, appVersion: '0.1.0', caps: { cameras: [], mics: [], displays: [] }, outputDir: '/mock', quality: 'recommended' }); state();
  });
  socket.on('message', raw => {
    const m = JSON.parse(raw.toString());
    if (!['start', 'stop'].includes(m.type)) return;
    if (handled.has(m.id)) { send('ack', { refId: m.id, ok: true }); return; }
    if (m.type === 'start' && status !== 'ready') { send('ack', { refId: m.id, ok: false, error: 'CLIENT_NOT_READY' }); return; }
    handled.add(m.id); send('ack', { refId: m.id, ok: true });
    console.log(`${m.operator}: ${m.type}`);
    if (m.type === 'start') {
      tracks = m.payload.tracks; status = 'countdown'; let left = 3;
      send('countdown', { secondsLeft: left }); state();
      countdown = setInterval(() => {
        left--;
        if (left > 0) send('countdown', { secondsLeft: left });
        else { clearInterval(countdown); status = 'recording'; recordingId = `rec_${ulid()}`; startedAt = Date.now(); send('recording_started', { recordingId, startedAt, tracks }); state(); }
      }, 1000);
    } else {
      clearInterval(countdown);
      if (status === 'recording') send('recording_stopped', { recordingId, stoppedAt: Date.now(), files: tracks.map(track => ({ track, path: `/mock/${track}.mp4`, bytes: 1024, durationMs: Date.now() - startedAt })) });
      status = 'ready'; state();
    }
  });
  socket.on('error', error => console.error(error.message));
  socket.on('close', () => { if (!exiting) reconnect = setTimeout(connect, 2000); });
}
connect();
const heartbeat = setInterval(state, 2000);
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => { exiting = true; clearTimeout(reconnect); clearInterval(countdown); clearInterval(heartbeat); socket.close(); });
