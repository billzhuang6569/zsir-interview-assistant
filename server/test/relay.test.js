import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';
import { ulid } from 'ulid';
import { buildApp } from '../dist/app.js';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const hello = { name: '嘉宾', os: { platform: 'macos', version: '14', arch: 'arm64' }, appVersion: '0.1.0', caps: { cameras: [], mics: [], displays: [] }, outputDir: '/tmp', quality: 'recommended' };
const state = { status: 'ready', elapsedMs: 0, tracks: { cam: { enabled: true, ok: true }, screen: { enabled: true, ok: true } }, disk: { freeBytes: 1000000 }, warnings: [] };
const envelope = (type, payload, from = 'client', extra = {}) => ({ type, id: ulid(), ts: Date.now(), from, payload, ...extra });
async function peer(url) {
  const ws = new WebSocket(url), messages = [];
  ws.on('message', data => messages.push(JSON.parse(data)));
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  return { ws, messages, send: m => ws.send(JSON.stringify(m)), async wait(predicate) {
    for (let i = 0; i < 300; i++) { const index = messages.findIndex(predicate); if (index >= 0) return messages.splice(index, 1)[0]; await sleep(10); }
    assert.fail(`message not received: ${predicate}\n${JSON.stringify(messages)}`);
  } };
}
async function setup(t, options = {}) {
  const app = buildApp(options);
  t.after(() => app.close());
  await app.listen({ port: 0, host: '127.0.0.1' });
  const base = `ws://127.0.0.1:${app.server.address().port}`;
  const create = async () => (await app.inject({ method: 'POST', url: '/api/rooms', payload: { name: '测试采访', director: '李导', guests: ['嘉宾'] } })).json();
  return { app, base, create, async control(room) { return peer(`${base}/ws/control?room=${room.id}`); },
    async client(room, id = randomUUID()) { const p = await peer(`${base}/ws/client?code=${room.code}&client=${id}`); p.id = id; p.send(envelope('hello', hello)); p.send(envelope('state', state)); return p; } };
}
function command(client, type = 'start') { return envelope(type, type === 'start' ? { tracks: ['cam', 'screen'], countdownSec: 3 } : {}, 'control', { clientId: client.id, operator: '李导' }); }

test('room → mock → start → ack/countdown/recording → both controls; snapshot and stop persistence', async t => {
  const s = await setup(t), room = await s.create();
  assert.match(room.code, /^\d{6}$/);
  const a = await s.control(room), b = await s.control(room), c = await s.client(room);
  await a.wait(m => m.type === 'client_online');
  const start = command(c); a.send(start);
  assert.equal((await c.wait(m => m.id === start.id)).operator, '李导');
  c.send(envelope('ack', { refId: start.id, ok: true }));
  c.send(envelope('countdown', { secondsLeft: 3 }));
  c.send(envelope('recording_started', { recordingId: 'rec_test', startedAt: Date.now(), tracks: ['cam', 'screen'] }));
  for (const p of [a, b]) {
    assert.equal((await p.wait(m => m.type === 'ack' && m.payload.refId === start.id)).payload.ok, true);
    assert.equal((await p.wait(m => m.type === 'countdown')).clientId, c.id);
    await p.wait(m => m.type === 'recording_started');
    assert.equal((await p.wait(m => m.type === 'log' && m.payload.code === 'start')).payload.actor, '李导');
  }
  const reconnect = await s.control(room);
  const snapshot = (await reconnect.wait(m => m.type === 'room')).payload;
  assert.equal(snapshot.clients[0].lastState.status, 'recording');
  assert.equal(snapshot.recordings[0].recordingId, 'rec_test');
  const stop = command(c, 'stop'); b.send(stop); await c.wait(m => m.id === stop.id);
  c.send(envelope('ack', { refId: stop.id, ok: true }));
  c.send(envelope('recording_stopped', { recordingId: 'rec_test', stoppedAt: Date.now(), files: [{ track: 'cam', path: '/mock/cam.mp4', bytes: 1024, durationMs: 1000 }] }));
  for (const p of [a, b]) await p.wait(m => m.type === 'recording_stopped');
  const final = await a.wait(m => m.type === 'room' && m.payload.recordings[0]?.stoppedAt);
  assert.equal(final.payload.recordings[0].files[0].bytes, 1024);
});

test('30s state timeout; offline start rejected; only latest stop replayed and ack clears it', async t => {
  let now = Date.now();
  const s = await setup(t, { now: () => now, tickMs: 10 }), room = await s.create();
  const a = await s.control(room), c = await s.client(room);
  await a.wait(m => m.type === 'client_online');
  now += 30001;
  await a.wait(m => m.type === 'client_offline');
  const start = command(c); a.send(start);
  assert.equal((await a.wait(m => m.type === 'ack' && m.payload.refId === start.id)).payload.error, 'CLIENT_OFFLINE');
  const first = command(c, 'stop'), last = command(c, 'stop'); a.send(first); a.send(last);
  await a.wait(m => m.type === 'ack' && m.payload.refId === last.id);
  c.ws.close();
  const again = await s.client(room, c.id);
  await again.wait(m => m.id === last.id);
  assert.equal(again.messages.some(m => m.id === first.id || m.id === start.id), false);
  again.send(envelope('ack', { refId: last.id, ok: true }));
  await a.wait(m => m.type === 'ack' && m.payload.refId === last.id && !m.payload.queued);
  again.ws.close();
  const third = await s.client(room, c.id); await sleep(60);
  assert.equal(third.messages.some(m => m.type === 'stop'), false);
});

test('ack timeout, cross-room routing and invalid messages', async t => {
  const s = await setup(t, { ackMs: 60 }), room = await s.create(), other = await s.create();
  const a = await s.control(room), c = await s.client(room), outsider = await s.control(other);
  await a.wait(m => m.type === 'client_online');
  const start = command(c); a.send(start); await c.wait(m => m.id === start.id);
  assert.equal((await a.wait(m => m.type === 'ack')).payload.error, 'ACK_TIMEOUT');
  outsider.send(command(c));
  assert.equal((await outsider.wait(m => m.type === 'ack')).payload.error, 'CLIENT_NOT_FOUND');
  const invalid = command(c); invalid.payload.countdownSec = 0; a.send(invalid);
  assert.equal((await a.wait(m => m.type === 'ack' && m.payload.refId === invalid.id)).payload.error, 'INVALID_COMMAND');
  c.send(envelope('future_message', {})); c.send(envelope('state', state));
  assert.equal(c.ws.readyState, WebSocket.OPEN);
  c.ws.send('{invalid');
  const code = await new Promise(resolve => c.ws.once('close', resolve)); assert.equal(code, 1008);
});

test('HTTP validation, lock on fifth failure, unlock after 10min, archive and expiry', async t => {
  let now = Date.now(); const s = await setup(t, { now: () => now }), room = await s.create();
  const joinCode = code => s.app.inject(`/api/join?code=${code}`);
  const badCode = room.code === '000000' ? '000001' : '000000';
  assert.equal((await s.app.inject({ method: 'POST', url: '/api/rooms', payload: { name: ' ', director: 'x' } })).statusCode, 400);
  for (let i = 0; i < 5; i++) assert.equal((await joinCode(badCode)).statusCode, 403);
  assert.equal((await joinCode(room.code)).statusCode, 403);
  now += 600001; assert.equal((await joinCode(room.code)).statusCode, 200);
  now += 7 * 86400000; assert.equal((await joinCode(room.code)).statusCode, 403);
  const fresh = await s.create();
  assert.equal((await s.app.inject({ method: 'POST', url: `/api/rooms/${fresh.id}/archive` })).statusCode, 200);
  assert.equal((await joinCode(fresh.code)).statusCode, 403);
});

test('SQLite restart preserves room/code/client/log/recording and pending stop', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'zsir-test-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const dbPath = join(dir, 'relay.sqlite');
  const s = await setup(t, { dbPath }), room = await s.create(), a = await s.control(room), c = await s.client(room);
  await a.wait(m => m.type === 'client_online');
  c.send(envelope('recording_started', { recordingId: 'persist', startedAt: Date.now(), tracks: ['cam'] }));
  await a.wait(m => m.type === 'recording_started');
  c.ws.close(); await a.wait(m => m.type === 'client_offline');
  const stop = command(c, 'stop'); a.send(stop); await a.wait(m => m.type === 'ack' && m.payload.queued);
  await s.app.close();
  const next = await setup(t, { dbPath });
  assert.equal((await next.app.inject(`/api/join?code=${room.code}`)).statusCode, 200);
  const control = await next.control(room), snapshot = (await control.wait(m => m.type === 'room')).payload;
  assert.equal(snapshot.clients[0].online, false); assert.equal(snapshot.recordings[0].recordingId, 'persist');
  assert.ok(snapshot.log.some(e => e.actor === '李导' && e.code === 'stop'));
  const rejoined = await next.client(room, c.id); await rejoined.wait(m => m.id === stop.id);
});

test('client handshake uses same IP lock as HTTP and rejects wrong code', async t => {
  const s = await setup(t), room = await s.create();
  const bad = room.code === '000000' ? '000001' : '000000';
  for (let i = 0; i < 5; i++) {
    const ws = new WebSocket(`${s.base}/ws/client?code=${bad}&client=${randomUUID()}`);
    await new Promise((resolve, reject) => {
      ws.on('unexpected-response', (_, response) => { assert.equal(response.statusCode, 403); response.resume(); ws.terminate(); resolve(); }); ws.on('error', () => {}); ws.on('open', reject);
    });
  }
  assert.equal((await s.app.inject({ url: `/api/join?code=${room.code}`, remoteAddress: '127.0.0.1' })).statusCode, 403);
});

test('state recovery replays stop without reconnect; reconnect before ack timeout also replays', async t => {
  let now = Date.now(); const s = await setup(t, { now: () => now, tickMs: 10 });
  const room = await s.create(), a = await s.control(room), c = await s.client(room);
  await a.wait(m => m.type === 'client_online'); now += 30001;
  await a.wait(m => m.type === 'client_offline');
  const stop = command(c, 'stop'); a.send(stop); await a.wait(m => m.type === 'ack' && m.payload.queued);
  c.send(envelope('state', state)); await c.wait(m => m.id === stop.id);
  c.ws.close();
  const reconnected = await s.client(room, c.id); await reconnected.wait(m => m.id === stop.id);
  reconnected.send(envelope('ack', { refId: stop.id, ok: true }));
  await a.wait(m => m.type === 'ack' && !m.payload.queued && m.payload.refId === stop.id);
});

test('same UUID can change rooms without carrying old pending stop', async t => {
  const s = await setup(t), room = await s.create(), nextRoom = await s.create();
  const a = await s.control(room), c = await s.client(room);
  await a.wait(m => m.type === 'client_online'); c.ws.close(); await a.wait(m => m.type === 'client_offline');
  const stop = command(c, 'stop'); a.send(stop); await a.wait(m => m.type === 'ack' && m.payload.queued);
  const b = await s.control(nextRoom), moved = await s.client(nextRoom, c.id); await b.wait(m => m.type === 'client_online');
  assert.equal(moved.messages.some(m => m.type === 'stop'), false);
  a.send(command(c)); assert.equal((await a.wait(m => m.type === 'ack' && !m.payload.queued)).payload.error, 'CLIENT_NOT_FOUND');
});

test('static control hosting; missing API paths are not SPA HTML', async t => {
  const publicDir = await mkdtemp(join(tmpdir(), 'zsir-static-'));
  t.after(() => rm(publicDir, { recursive: true, force: true }));
  await writeFile(join(publicDir, 'index.html'), '<div id="root"></div>');
  const s = await setup(t, { publicDir });
  const html = await s.app.inject('/');
  assert.equal(html.statusCode, 200); assert.match(html.body, /<div id="root">/);
  assert.equal((await s.app.inject('/api/missing')).statusCode, 404);
});
