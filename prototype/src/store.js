// shortcut: same-browser tabs only; replace with the relay protocol for cross-device control.
import { initial, reduce } from "./model.mjs";
const KEY = "zsir-prototype-v1";
export function read() {
  try {
    return JSON.parse(localStorage.getItem(KEY)) || initial();
  } catch {
    return initial();
  }
}
export async function send(action) {
  return navigator.locks.request(KEY, () => {
    const current = read();
    const next = reduce(current, action);
    if (next !== current) {
      localStorage.setItem(KEY, JSON.stringify(next));
      window.dispatchEvent(new Event("prototype-change"));
    }
    return next;
  });
}
