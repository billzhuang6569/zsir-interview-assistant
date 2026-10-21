export type Room = { id: string; name: string; code: string; director: string; welcome: string; guests: string[]; defaultTracks: string[]; createdAt: number; expiresAt: number; archivedAt: number | null };
export type Client = { clientId: string; name: string; os: { platform: string; version: string }; appVersion: string; online: boolean; lastState: { status: string; elapsedMs?: number; disk?: { freeBytes: number }; warnings?: string[] } | null; countdown?: number | null };
export type Log = { id?: string; ts: number; actor: string; text: string; level: string };
export type Snapshot = { room: Room; clients: Client[]; log: Log[]; recordings: unknown[] };
export type Message = { type: string; id: string; ts: number; from: string; clientId?: string; operator?: string; payload: any };
