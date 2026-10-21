import type { Message } from './types';
// Uses Web Crypto on HTTPS and getRandomValues on plain HTTP LAN deployments.
export function newId() {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  let time = Date.now(), prefix = '';
  for (let i = 0; i < 10; i++) { prefix = alphabet[time % 32] + prefix; time = Math.floor(time / 32); }
  return prefix + Array.from(crypto.getRandomValues(new Uint8Array(16)), n => alphabet[n & 31]).join('');
}
export function connect(room: string, receive: (m: Message) => void, status: (connected: boolean) => void) {
  let socket: WebSocket, timer: ReturnType<typeof setTimeout>, disposed = false;
  function open() {
    socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws/control?room=${encodeURIComponent(room)}`);
    socket.onopen = () => { if (!disposed) status(true); };
    socket.onmessage = event => { if (!disposed) receive(JSON.parse(event.data)); };
    socket.onclose = () => { if (!disposed) { status(false); timer = setTimeout(open, 1500); } };
    socket.onerror = () => socket.close();
  }
  open();
  return {
    send(m: Message) { if (socket.readyState !== WebSocket.OPEN) return false; socket.send(JSON.stringify(m)); return true; },
    close() { disposed = true; clearTimeout(timer); socket.close(); },
  };
}
