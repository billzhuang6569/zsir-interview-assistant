import { useEffect, useRef, useState, type FormEvent } from 'react';
import { connect, newId } from './ws';
import type { Client, Message, Room, Snapshot } from './types';

const labels: Record<string, string> = { idle: '待准备', preflight: '自检中', ready: '就绪', countdown: '倒计时', recording: '录制中', stopping: '正在停止', postprocess: '处理中', uploading: '上传中', error: '异常' };
const errors: Record<string, string> = { CLIENT_OFFLINE: '嘉宾已离线，开始指令未发送', CLIENT_NOT_READY: '嘉宾尚未就绪', ACK_TIMEOUT: '嘉宾未在 5 秒内确认，请检查状态后重试', ROOM_INACTIVE: '房间已归档或邀请码已过期', CLIENT_NOT_FOUND: '未找到嘉宾', INVALID_COMMAND: '指令参数无效' };
const duration = (ms = 0) => [Math.floor(ms / 3600000), Math.floor(ms / 60000) % 60, Math.floor(ms / 1000) % 60].map(n => String(n).padStart(2, '0')).join(':');
const trackValue = (tracks: string[]) => tracks.length === 2 ? 'both' : tracks[0];
const trackList = (value: string) => value === 'both' ? ['cam', 'screen'] : [value];
function Scope({ value, onChange, disabled = false }: { value: string; onChange: (s: string) => void; disabled?: boolean }) {
  return <label className="scope">录制范围 <select value={value} onChange={e => onChange(e.target.value)} disabled={disabled}><option value="both">两路</option><option value="cam">仅摄像头</option><option value="screen">仅屏幕</option></select></label>;
}
async function api(path: string, body?: unknown) {
  const response = await fetch(path, body === undefined ? undefined : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!response.ok) throw new Error(`请求失败（${response.status}）`);
  return response.json();
}
function ClientCard({ client: c, room, enabled, pending, command, error }: { client: Client; room: Room; enabled: boolean; pending?: string; command: (id: string, type: string, payload: unknown) => void; error?: string }) {
  const [scope, setScope] = useState(trackValue(room.defaultTracks));
  const dialog = useRef<HTMLDialogElement>(null);
  const state = c.lastState;
  const busy = ['recording', 'countdown', 'stopping'].includes(state?.status ?? '') || c.countdown != null;
  return <section className="client" aria-label={`嘉宾 ${c.name}`}>
    <div className="card-head"><strong>{c.name}</strong><span className="muted">{c.os.platform} {c.os.version} · v{c.appVersion}</span><span className="grow" /><span className={c.online ? 'green' : 'muted'}>{c.online ? '● 在线' : '○ 离线'}</span><strong className={busy ? 'red' : ''}>{labels[state?.status ?? ''] ?? '等待状态'}</strong><time>{duration(state?.elapsedMs)}</time></div>
    <div className="card-body"><div className="frames"><div>CAM · 摄像头<span>静帧预览尚未接入</span></div><div>SCREEN · 桌面<span>静帧预览尚未接入</span></div></div>
      {c.online && c.countdown != null && <div className="countdown" aria-live="assertive"><b>{c.countdown}</b><span>即将开始录制</span></div>}
      <p className="muted">{state?.disk ? `磁盘剩余 ${(state.disk.freeBytes / 1e9).toFixed(1)} GB` : '等待嘉宾设备状态'}{state?.warnings?.length ? ` · 警告：${state.warnings.join('、')}` : ''}</p>
    </div>
    <div className="actions"><Scope value={scope} onChange={setScope} disabled={!enabled || !!pending || busy} /><span className="grow" /><button disabled={!enabled || !!pending || !c.online || state?.status !== 'ready'} onClick={() => command(c.clientId, 'start', { tracks: trackList(scope), countdownSec: 3 })}>● 开始录制</button><button className="danger" disabled={!enabled || !!pending} onClick={() => dialog.current?.showModal()}>■ 停止录制</button></div>
    {pending && <p className="notice" role="status">发送中，等待嘉宾确认…</p>}{error && <p className="notice" role="status">{error}</p>}
    {!c.online && <p className="muted notice">嘉宾离线；停止指令将在重连后补发。</p>}
    <dialog ref={dialog}><h2>停止 {c.name} 的录制？</h2><p>已录制 {duration(state?.elapsedMs)}。{!c.online && '嘉宾离线，停止指令会保留至重连。'}</p><div className="actions"><button onClick={() => dialog.current?.close()}>取消</button><button className="danger" onClick={() => { dialog.current?.close(); command(c.clientId, 'stop', {}); }}>确认停止</button></div></dialog>
  </section>;
}
export function App() {
  const [nickname, setNickname] = useState(() => localStorage.getItem('zsir-nickname') ?? '');
  const [rooms, setRooms] = useState<Room[]>([]), [selected, setSelected] = useState('');
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null), [connected, setConnected] = useState(false);
  const [error, setError] = useState(''), [notice, setNotice] = useState(''), [creating, setCreating] = useState(false);
  const [pending, setPending] = useState<Record<string, string>>({}), [clientErrors, setClientErrors] = useState<Record<string, string>>({});
  const connection = useRef<ReturnType<typeof connect>>();
  const newRoom = useRef<HTMLDialogElement>(null);
  const [defaultScope, setDefaultScope] = useState('both');
  const refresh = async () => { try { const list: Room[] = await api('/api/rooms'); setRooms(list); setError(''); setSelected(current => current || list[0]?.id || ''); } catch { setError('无法连接服务器，请检查网络后重试'); } };
  useEffect(() => { void refresh(); const timer = setInterval(() => void refresh(), 10000); return () => clearInterval(timer); }, []);
  useEffect(() => { localStorage.setItem('zsir-nickname', nickname); }, [nickname]);
  useEffect(() => {
    setSnapshot(null); setConnected(false); setPending({}); setClientErrors({});
    if (!selected) return;
    connection.current = connect(selected, (m: Message) => {
      if (m.type === 'room') { setSnapshot(m.payload); setRooms(list => list.map(r => r.id === selected ? m.payload.room : r)); }
      else if (m.type === 'log') setSnapshot(s => s && ({ ...s, log: [...s.log, m.payload].slice(-200) }));
      else if (m.type === 'ack') {
        setPending(values => Object.fromEntries(Object.entries(values).filter(([, id]) => id !== m.payload.refId)));
        if (m.clientId) setClientErrors(values => ({ ...values, [m.clientId!]: m.payload.ok ? (m.payload.queued ? '停止指令已保存，等待嘉宾重连' : '') : errors[m.payload.error] ?? `操作失败：${m.payload.error}` }));
      } else setSnapshot(s => {
        if (!s) return s;
        const id = m.clientId ?? m.payload.clientId;
        return { ...s, clients: s.clients.map(c => {
          if (c.clientId !== id) return c;
          if (m.type === 'client_state') return { ...c, lastState: m.payload.state, countdown: m.payload.state.status === 'countdown' ? c.countdown : null };
          if (m.type === 'client_online' || m.type === 'client_offline') return { ...c, online: m.type === 'client_online', countdown: null };
          if (m.type === 'countdown') return { ...c, countdown: m.payload.secondsLeft, lastState: { ...c.lastState, status: 'countdown' } };
          return c;
        }) };
      });
    }, online => { setConnected(online); if (online) setNotice(''); else { setPending({}); setSnapshot(s => s && ({ ...s, clients: s.clients.map(c => ({ ...c, online: false, countdown: null })) })); setNotice('连接中断，操作结果请以重连后的状态为准'); } });
    return () => connection.current?.close();
  }, [selected]);
  useEffect(() => {
    const c = snapshot?.clients.find(c => c.online && c.lastState?.status === 'recording');
    document.title = c ? `● 录制中 ${duration(c.lastState?.elapsedMs)} · ${c.name}` : '庄Sir线上采访助手 · 控制端';
  }, [snapshot]);
  const command = (clientId: string, type: string, payload: unknown) => {
    if (!nickname.trim() || !connected) return;
    const id = newId();
    if (connection.current?.send({ type, id, ts: Date.now(), from: 'control', clientId, operator: nickname.trim(), payload })) {
      setPending(p => ({ ...p, [clientId]: id })); setClientErrors(p => ({ ...p, [clientId]: '' }));
    }
  };
  const copy = async (text: string) => {
    try {
      if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(text);
      else { const area = document.createElement('textarea'); area.value = text; area.style.position = 'fixed'; document.body.append(area); area.select(); const copied = document.execCommand('copy'); area.remove(); if (!copied) throw new Error('请手动复制邀请码'); }
      setNotice('已复制');
    } catch { setNotice('复制失败，请手动复制邀请码'); }
  };
  const create = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault(); setCreating(true); setError('');
    const form = event.currentTarget, fields = new FormData(form);
    try {
      const r = await api('/api/rooms', { name: fields.get('name'), director: fields.get('director'), guests: String(fields.get('guests')).split(/[\n,，]/).map(s => s.trim()).filter(Boolean), welcome: fields.get('welcome'), defaultTracks: trackList(defaultScope) });
      await refresh(); setSelected(r.id); newRoom.current?.close(); form.reset();
    } catch (e) { setError(String(e)); } finally { setCreating(false); }
  };
  const room = snapshot?.room;
  const active = !!room && !room.archivedAt && room.expiresAt > Date.now();
  return <><header><strong><span className="red">●</span> 庄Sir线上采访助手</strong><span className="muted">控制端</span><span className="grow" /><label>我是 <input aria-label="操作者昵称" maxLength={80} placeholder="请先填写昵称" value={nickname} onChange={e => setNickname(e.target.value)} /></label><span className={connected ? 'green' : 'red'}>{connected ? '● 已连接服务器' : selected ? '○ 与服务器断开，重连中…' : '请选择或创建房间'}</span><button disabled={!nickname.trim() || (!!selected && !connected)} onClick={() => newRoom.current?.showModal()}>+ 新建房间</button></header>
    <div className="layout"><nav aria-label="房间列表"><h2>房间列表</h2>{['今天', '最近 7 天', '更早'].map(group => {
      const list = rooms.filter(r => (new Date(r.createdAt).toDateString() === new Date().toDateString() ? '今天' : Date.now() - r.createdAt < 7 * 86400000 ? '最近 7 天' : '更早') === group);
      return list.length ? <div key={group}><p className="muted">{group}</p>{list.map(r => <button key={r.id} className={selected === r.id ? 'selected' : ''} onClick={() => setSelected(r.id)} aria-current={selected === r.id ? 'page' : undefined}>{r.name}<small>{r.archivedAt ? '已归档' : r.expiresAt <= Date.now() ? '已过期' : '邀请码有效'}</small></button>)}</div> : null;
    })}</nav><main>
      {error && <p role="alert" className="red">{error}</p>}{notice && <p role="status">{notice}</p>}{!nickname.trim() && <p className="notice">请先在顶栏填写昵称，操作记录会显示这个名字。</p>}
      {room ? <><section className="room-head"><div><h1>{room.name}</h1><p className="muted">导演：{room.director} · 有效至 {new Date(room.expiresAt).toLocaleString()}</p></div><div className="invite"><span>邀请码</span><b>{room.code.slice(0, 3)} {room.code.slice(3)}</b><button onClick={() => void copy(room.code)}>复制</button></div><button onClick={() => void copy(`您好，这是我们采访用的录制小程序：\n1. 下载安装：${location.origin}/download\n2. 按提示允许权限、检查画面\n3. 最后一步输入邀请码：${room.code}\n装好后会显示「已连接导演」，就可以等我们开始了。`)}>复制邀请文案</button>{!active && <strong className="red">房间只读：已归档或已过期</strong>}</section>
      {snapshot.clients.length ? snapshot.clients.map(c => <ClientCard key={`${room.id}:${c.clientId}`} client={c} room={room} enabled={connected && active && !!nickname.trim()} command={command} pending={pending[c.clientId]} error={clientErrors[c.clientId]} />) : <section className="empty">等待嘉宾输入邀请码加入房间</section>}
      <section className="log"><h2>事件日志</h2><div role="log">{snapshot.log.length ? [...snapshot.log].reverse().map((entry, i) => <p key={entry.id ?? i} className={entry.level === 'error' ? 'red' : ''}><time>{new Date(entry.ts).toLocaleTimeString()}</time><strong>{entry.actor}</strong><span>{entry.text}</span></p>) : <p className="muted">暂无事件</p>}</div></section></> : <section className="empty">{selected ? '正在同步房间…' : '创建一个房间，邀请嘉宾开始采访'}</section>}
    </main></div>
    <dialog ref={newRoom}><form onSubmit={create}><h2>新建房间</h2><label>房间名<input name="name" required maxLength={200} autoFocus /></label><label>导演<input name="director" required maxLength={80} defaultValue={nickname} /></label><label>嘉宾姓名（每行一位，或逗号分隔）<textarea name="guests" maxLength={4000} /></label><label>欢迎语<textarea name="welcome" maxLength={2000} /></label><Scope value={defaultScope} onChange={setDefaultScope} />{error && <p role="alert" className="red">{error}</p>}<div className="actions"><button type="button" onClick={() => newRoom.current?.close()}>取消</button><button disabled={creating}>{creating ? '创建中…' : '创建房间'}</button></div></form></dialog>
  </>;
}
