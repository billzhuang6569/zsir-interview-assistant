import Fastify from 'fastify';
import staticFiles from '@fastify/static';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { openStore } from './store/db.js';
import { createHub } from './ws/hub.js';

export function buildApp(options: { dbPath?: string; publicDir?: string; now?: () => number; offlineMs?: number; ackMs?: number; tickMs?: number } = {}) {
  const app = Fastify({ bodyLimit: 64 * 1024 });
  const store = openStore(options.dbPath ?? ':memory:');
  const now = options.now ?? Date.now;
  // shortcut: single-process IP limiter resets on restart; persist it if deployment becomes multi-process.
  const failures = new Map<string, { count: number; until: number }>();
  const authorize = (code: string, ip: string) => {
    const key = ip.replace(/^::ffff:/, '');
    const previous = failures.get(key);
    if (previous && previous.until <= now()) failures.delete(key);
    const attempt = failures.get(key);
    if (attempt && attempt.count >= 5) return null;
    const room = /^\d{6}$/.test(code) ? store.join(code, now()) : null;
    if (room) { failures.delete(key); return room; }
    failures.set(key, { count: (attempt?.count ?? 0) + 1, until: now() + 600000 });
    return null;
  };
  const cleanup = setInterval(() => { for (const [ip, value] of failures) if (value.until <= now()) failures.delete(ip); }, 60000);
  const hub = createHub(app.server, store, authorize, { now, offlineMs: options.offlineMs ?? 30000, ackMs: options.ackMs ?? 5000, tickMs: options.tickMs ?? 1000 });
  app.addHook('preClose', async () => { clearInterval(cleanup); hub.close(); });
  app.addHook('onClose', async () => { store.db.close(); });
  app.get('/healthz', async () => ({ ok: true }));
  app.get('/api/rooms', async () => store.rooms());
  app.post('/api/rooms', { schema: { body: {
    type: 'object', required: ['name', 'director'], additionalProperties: false,
    properties: {
      name: { type: 'string', minLength: 1, maxLength: 200, pattern: '\\S' },
      director: { type: 'string', minLength: 1, maxLength: 80, pattern: '\\S' },
      welcome: { type: 'string', maxLength: 2000 },
      guests: { type: 'array', maxItems: 50, items: { type: 'string', minLength: 1, maxLength: 80, pattern: '\\S' } },
      defaultTracks: { type: 'array', minItems: 1, maxItems: 2, uniqueItems: true, items: { enum: ['cam', 'screen'] } },
    },
  } } }, async (request, reply) => {
    const room = store.create(request.body, now());
    reply.code(201);
    return { id: room.id, code: room.code, expiresAt: room.expiresAt };
  });
  app.get<{ Querystring: { code?: string } }>('/api/join', async (request, reply) => {
    const room = authorize(request.query.code ?? '', request.ip);
    if (!room) return reply.code(403).send({ error: 'INVALID_CODE' });
    const { id, name, director, welcome, guests, defaultTracks } = room;
    return { room: { id, name, director, welcome, guests, defaultTracks } };
  });
  app.post<{ Params: { id: string } }>('/api/rooms/:id/archive', async (request, reply) => {
    if (!store.room(request.params.id)) return reply.code(404).send({ error: 'ROOM_NOT_FOUND' });
    store.db.prepare('UPDATE rooms SET archived_at=COALESCE(archived_at,?) WHERE id=?').run(now(), request.params.id);
    hub.refresh(request.params.id);
    return { ok: true };
  });
  const root = options.publicDir ?? fileURLToPath(new URL('../../control/dist/', import.meta.url));
  if (existsSync(root)) app.register(staticFiles, { root });
  return app;
}
