export const initial = () => ({
  version: 0,
  previewAt: Date.now(),
  config: {
    摄像头: "FaceTime HD Camera",
    话筒: "MacBook Pro 麦克风",
    显示器: "内建显示器",
    系统声音: "默认输出设备",
    输出目录: "影片 / 庄Sir采访 / 今日采访",
  },
  phase: "ready",
  tracks: { desktop: true, camera: true },
  connected: true,
  takes: [],
  lastAction: "等待开始",
  deadline: 0,
  startedAt: 0,
  elapsed: 0,
  failSave: false,
  endRequested: false,
  sheet: false,
});
export const duration = (s, now) =>
  s.phase === "recording"
    ? Math.max(0, Math.floor((now - s.startedAt) / 1000))
    : s.elapsed;
export function reduce(s, a, now = Date.now()) {
  if (a.expected !== undefined && a.expected !== s.version) return s;
  if (a.remote && !s.connected && !["network", "reset"].includes(a.type))
    return s;
  let next = { ...s };
  const finish = () => {
    next.elapsed = duration(s, now);
    next.phase = "saving";
    next.deadline = now + 1800;
  };
  switch (a.type) {
    case "reset":
      next = initial();
      break;
    case "demo":
      next = {
        ...initial(),
        phase: "recording",
        startedAt: now - 756000,
        lastAction: "操作员02 开始录制",
      };
      break;
    case "network":
      next.connected = !s.connected;
      next.disconnectedAt = now;
      if (!next.connected && s.phase === "countdown" && s.startRemote)
        next.phase = "ready";
      break;
    case "failure":
      next.failSave = !s.failSave;
      break;
    case "inspect":
      if (s.endRequested || ["ending", "closed"].includes(s.phase)) return s;
      next.previewAt = now;
      break;
    case "configure":
      if (!["ready", "saved"].includes(s.phase)) return s;
      next.config = { ...s.config, [a.field]: a.value };
      break;
    case "tracks":
      if (!["ready", "saved"].includes(s.phase)) return s;
      next.tracks = { ...s.tracks, [a.track]: !s.tracks[a.track] };
      break;
    case "start":
      if (
        !["ready", "saved"].includes(s.phase) ||
        !Object.values(s.tracks).some(Boolean)
      )
        return s;
      next.phase = "countdown";
      next.startRemote = !!a.remote;
      next.deadline = now + 3000;
      next.sheet = false;
      next.elapsed = 0;
      break;
    case "trial":
      if (!["ready", "saved"].includes(s.phase)) return s;
      next.phase = "trial";
      next.elapsed = 0;
      next.deadline = now + 10000;
      next.trialDone = false;
      break;
    case "cancel":
      if (s.phase !== "countdown") return s;
      next.phase = "ready";
      break;
    case "stop":
      if (s.phase !== "recording") return s;
      finish();
      break;
    case "end":
      if (["ending", "closed"].includes(s.phase) || s.endRequested) return s;
      next.endRequested = true;
      next.sheet = false;
      if (s.phase === "recording") finish();
      else if (!["saving", "save_failed"].includes(s.phase)) {
        next.phase = "ending";
        next.deadline = now + 3000;
      }
      break;
    case "retry":
      if (s.phase !== "save_failed") return s;
      next.phase = "saving";
      next.deadline = now + 1800;
      next.failSave = false;
      break;
    case "sheet":
      if (!s.takes.length || s.endRequested) return s;
      next.sheet = true;
      break;
    case "tick":
      if (now < s.deadline) return s;
      if (s.phase === "trial") {
        next.phase = "ready";
        next.trialDone = true;
      } else if (s.phase === "countdown") {
        next.phase = "recording";
        next.startedAt = now;
      } else if (s.phase === "saving") {
        if (s.failSave) {
          next.phase = "save_failed";
          break;
        }
        next.takes = [
          ...s.takes,
          {
            id: s.takes.length + 1,
            duration: s.elapsed,
            tracks: { ...s.tracks },
            createdAt: now,
          },
        ];
        next.phase = s.endRequested ? "ending" : "saved";
        next.deadline = now + 3000;
      } else if (s.phase === "ending") {
        next.phase = "closed";
        next.connected = false;
      } else if (s.phase === "recording" && s.connected) {
        next.previewAt = now;
      } else return s;
      break;
    default:
      return s;
  }
  next.version = s.version + 1;
  if (a.type !== "tick")
    next.lastAction = `${a.actor || "本地演示"} · ${{ configure: "修改设备设置", inspect: "检查画面", trial: "开始10秒试录", start: "开始录制", stop: "停止录制", end: "结束任务", cancel: "取消倒计时", tracks: "更改机位", network: "切换网络", retry: "重试保存", sheet: "检查素材", reset: "重置演示", failure: "设置保存故障", demo: "载入录制示例" }[a.type] || a.type}`;
  return next;
}
export function frameTimes(seconds) {
  return [
    ...new Set([
      0,
      ...Array.from(
        { length: Math.floor(Math.max(0, seconds - 1) / 30) },
        (_, i) => (i + 1) * 30,
      ),
      Math.max(0, seconds - 1),
    ]),
  ].sort((a, b) => a - b);
}
