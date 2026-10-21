import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomInt } from 'node:crypto';
import { ulid } from 'ulid';

export function openStore(path: string) {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS rooms (id TEXT PRIMARY KEY, name TEXT NOT NULL, code TEXT UNIQUE NOT NULL,
      director TEXT NOT NULL, welcome TEXT NOT NULL, guests_json TEXT NOT NULL, default_tracks TEXT NOT NULL,
      created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, archived_at INTEGER);
    CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, name TEXT NOT NULL,
      os_json TEXT NOT NULL, app_version TEXT NOT NULL, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
      pending_command TEXT);
    CREATE TABLE IF NOT EXISTS recordings (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, client_id TEXT NOT NULL,
      started_at INTEGER NOT NULL, stopped_at INTEGER, tracks_json TEXT NOT NULL, files_json TEXT);
    CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, client_id TEXT,
      ts INTEGER NOT NULL, actor TEXT NOT NULL, level TEXT NOT NULL, code TEXT NOT NULL, text TEXT NOT NULL, detail_json TEXT);
    CREATE INDEX IF NOT EXISTS events_room ON events(session_id, ts);
  `);
  const roomView = (r: any) => r && ({ id: r.id, name: r.name, code: r.code, director: r.director,
    welcome: r.welcome, guests: JSON.parse(r.guests_json), defaultTracks: JSON.parse(r.default_tracks),
    createdAt: r.created_at, expiresAt: r.expires_at, archivedAt: r.archived_at });
  return {
    db,
    room: (id: string) => roomView(db.prepare('SELECT * FROM rooms WHERE id=?').get(id)),
    rooms: () => db.prepare('SELECT * FROM rooms ORDER BY created_at DESC, id DESC').all().map(roomView),
    join: (code: string, now: number) => roomView(db.prepare('SELECT * FROM rooms WHERE code=? AND archived_at IS NULL AND expires_at>?').get(code, now)),
    create(input: any, now: number) {
      let code: string;
      do { code = String(randomInt(0, 1000000)).padStart(6, '0'); }
      while (db.prepare('SELECT id FROM rooms WHERE code=?').get(code));
      const id = ulid();
      db.prepare('INSERT INTO rooms VALUES (?,?,?,?,?,?,?,?,?,NULL)').run(id, input.name.trim(), code,
        input.director.trim(), input.welcome ?? '', JSON.stringify(input.guests ?? []),
        JSON.stringify(input.defaultTracks ?? ['cam', 'screen']), now, now + 7 * 86400000);
      return this.room(id);
    },
    clients(room: string) {
      return db.prepare('SELECT * FROM clients WHERE session_id=?').all(room).map((c: any) => ({
        clientId: c.id, name: c.name, os: JSON.parse(c.os_json), appVersion: c.app_version,
        online: false, lastState: null, lastFrames: {}, lastSeen: c.last_seen,
      }));
    },
    log(room: string, client: string | null, actor: string, level: string, code: string, text: string, detail: unknown = null) {
      const entry = { id: ulid(), ts: Date.now(), clientId: client, actor, level, code, text, detail };
      db.prepare('INSERT INTO events VALUES (?,?,?,?,?,?,?,?,?)').run(entry.id, room, client, entry.ts, actor, level, code, text, JSON.stringify(detail));
      return entry;
    },
    logs(room: string) {
      return db.prepare('SELECT * FROM (SELECT * FROM events WHERE session_id=? ORDER BY ts DESC, id DESC LIMIT 200) ORDER BY ts, id').all(room).map((e: any) => ({
        id: e.id, ts: e.ts, clientId: e.client_id, actor: e.actor, level: e.level, code: e.code, text: e.text, detail: JSON.parse(e.detail_json),
      }));
    },
    recordings(room: string) {
      return db.prepare('SELECT * FROM recordings WHERE session_id=? ORDER BY started_at').all(room).map((r: any) => ({
        recordingId: r.id, clientId: r.client_id, startedAt: r.started_at, stoppedAt: r.stopped_at,
        tracks: JSON.parse(r.tracks_json), files: JSON.parse(r.files_json ?? '[]'),
      }));
    },
  };
}
export type Store = ReturnType<typeof openStore>;
