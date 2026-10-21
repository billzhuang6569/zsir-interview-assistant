import { ulid } from 'ulid';
import { Ajv2020 } from 'ajv/dist/2020.js';
import { readFileSync } from 'node:fs';

export type Message = { type: string; id: string; ts: number; from: string; payload: any; clientId?: string; operator?: string };
export const message = (type: string, payload: unknown, clientId?: string): Message => ({ type, id: ulid(), ts: Date.now(), from: 'server', payload, ...(clientId ? { clientId } : {}) });
const ajv = new Ajv2020({ strict: false });
const schema = (name: string) => JSON.parse(readFileSync(new URL(`../../../protocol/schema/${name}.json`, import.meta.url), 'utf8'));
const envelope = ajv.compile(schema('envelope'));
const state = ajv.compile(schema('state'));
const event = ajv.compile(schema('event'));
const commands = ajv.compile(schema('commands'));
const str = (v: unknown) => typeof v === 'string' && v.length > 0 && v.length <= 500;
const num = (v: unknown) => Number.isSafeInteger(v) && (v as number) >= 0;
const tracks = (v: any) => Array.isArray(v) && v.length > 0 && v.length <= 2 && new Set(v).size === v.length && v.every((x: unknown) => x === 'cam' || x === 'screen');
export function parseMessage(data: string, from: string): Message | null {
  let m: Message;
  try { m = JSON.parse(data); } catch { return null; }
  if (!envelope(m) || m.from !== from || !/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/.test(m.id)) return null;
  return m;
}
export function validPayload(m: Message) {
  const p = m.payload;
  switch (m.type) {
    case 'start': return commands(m) && p.countdownSec === 3;
    case 'stop': return commands(m);
    case 'hello': return str(p.name) && p.os && str(p.os.platform) && str(p.os.version) && str(p.os.arch) && str(p.appVersion) && p.caps && ['cameras', 'mics', 'displays'].every(k => Array.isArray(p.caps[k])) && typeof p.outputDir === 'string' && ['economy', 'recommended', 'high'].includes(p.quality);
    case 'state': return state(p);
    case 'event': return event(p);
    case 'countdown': return Number.isInteger(p.secondsLeft) && p.secondsLeft >= 0 && p.secondsLeft <= 3;
    case 'recording_started': return str(p.recordingId) && num(p.startedAt) && tracks(p.tracks);
    case 'recording_stopped': return str(p.recordingId) && num(p.stoppedAt) && Array.isArray(p.files) && p.files.length <= 2 && p.files.every((f: any) => f && ['cam', 'screen'].includes(f.track) && str(f.path) && num(f.bytes) && num(f.durationMs));
    case 'ack': return str(p.refId) && typeof p.ok === 'boolean' && (p.error === undefined || str(p.error));
    default: return true;
  }
}
