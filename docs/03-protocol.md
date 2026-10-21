# 03 · 通信协议

所有消息为 UTF-8 JSON；WebSocket 文本帧；二进制（静帧、宫格图）走 HTTP。JSON Schema 在 `protocol/schema/`，三端共用。

## 1. 连接

| 端 | URL | 鉴权 |
|---|---|---|
| 客户端 | `wss://<host>/ws/client?code=<6位邀请码>&client=<uuid>` | 邀请码有效即允许，服务器据此把连接挂到对应房间；`client` 由客户端首次生成并持久化，重连沿用。邀请码错误/过期时以 HTTP 403 拒绝握手，body `{error:"INVALID_CODE"}` |
| 控制端 | `wss://<host>/ws/control?room=<房间 id>` | 当前版本无鉴权（内部使用） |

服务器每 10 秒发 ping，20 秒无 pong 断开。客户端每 2 秒主动发 `state`；30 秒无 `state` 服务器将其标记为 `offline` 并广播。

## 2. 通用信封

```json
{ "type": "state", "id": "01HX…", "ts": 1730000000123, "from": "client|control|server", "payload": { } }
```

- `id`：ULID，控制端用于把 `ack` 对应回按钮。
- `ts`：发送方毫秒时间戳。
- 不认识的 `type` 一律忽略不报错（向前兼容）。

## 3. 客户端 → 服务器

| type | payload | 说明 |
|---|---|---|
| `hello` | `{name, os:{platform,version,arch}, appVersion, caps:{cameras[],mics[],displays[]}, outputDir, quality}` | 连接后第一条；重连后重发 |
| `state` | 见下 | 每 2 秒心跳；状态变化时立即发 |
| `countdown` | `{secondsLeft}` | 倒计时每秒一条，控制端同步显示 |
| `recording_started` | `{recordingId, startedAt, tracks[]}` | 录制真正开始的那一刻 |
| `recording_stopped` | `{recordingId, stoppedAt, files:[{track,path,bytes,durationMs}]}` | 文件已 finalize |
| `contact_sheet_ready` | `{recordingId, track, url}` | 宫格图已上传，`url` 由服务器在 HTTP 上传响应里给出 |
| `upload_progress` | `{recordingId, track, bytesDone, bytesTotal, state:"uploading|paused|done|error", sha256?}` | |
| `event` | `{level:"info|warn|error", code, message, detail?}` | 告警/错误，服务器写日志并广播；`code` 见 §8 |
| `ack` | `{refId, ok, error?}` | 对每条控制指令的回执 |
| `finish_result` | `{ok, keptOutputDir}` | 结束任务执行结果（发送后立即断开） |

`state.payload`：

```json
{
  "status": "idle|preflight|ready|countdown|recording|stopping|uploading|error",
  "recordingId": "rec_…",
  "elapsedMs": 872000,
  "tracks": {
    "cam":    { "enabled": true, "ok": true, "width":1920, "height":1080, "fps":29.9, "bitrateKbps":10900, "bytes": 1180000000, "level": -18.2 },
    "screen": { "enabled": true, "ok": true, "width":2560, "height":1440, "fps":30.0, "bitrateKbps":9700,  "bytes": 1050000000, "level": -32.0 }
  },
  "disk": { "freeBytes": 335000000000, "estimatedMinutesLeft": 540 },
  "warnings": ["DISK_LOW"]
}
```

## 4. 控制端 → 服务器 → 客户端

服务器校验房间后原样转发给目标客户端，并把「谁点了什么」写入事件日志广播给所有控制端。

| type | payload | 客户端行为 |
|---|---|---|
| `snapshot` | `{}` | 立刻抓两路当前帧并 HTTP 上传 |
| `start` | `{tracks:["cam","screen"], countdownSec:3}` | 进入 `countdown`，每秒发 `countdown`，到 0 开录 |
| `stop` | `{}` | 停止并 finalize，随后自动生成宫格图并开始上传 |
| `set_quality` | `{preset:"economy|recommended|high"}` | 仅 `idle/ready` 时可用 |
| `make_contact_sheet` | `{recordingId}` | 重新生成（通常自动触发，此为手动补发） |
| `upload_control` | `{action:"pause|resume|retry"}` | |
| `finish_task` | `{keepOutputDir:true}` | 弹确认 → 卸载 |

每条指令带 `operator`（控制端昵称）字段由服务器注入，客户端在浮窗显示「李导 正在开始录制」。

## 5. 服务器 → 控制端

| type | payload |
|---|---|
| `room` | 完整房间快照：`{room:{id,name,code,director,welcome,guests[],createdAt,expiresAt}, clients:[{clientId,name,os,appVersion,online,lastState,lastFrames:{cam:{url,ts},screen:{url,ts}}}], recordings:[…], log:[…最近 200 条]}`，连接时与房间变化时发 |
| `client_state` | `{clientId, state}`（转发） |
| `client_online` / `client_offline` | `{clientId}` |
| `frame` | `{clientId, track, url, ts}` 静帧更新 |
| `log` | `{ts, actor, text, level}` |
| `ack` | 转发客户端回执 |
| 其余客户端上行消息 | 原样转发（带 `clientId`） |

## 6. HTTP 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/rooms` | 控制端新建房间 `{name, director, guests?:[string], welcome?, defaultTracks?}` → `{id, code, expiresAt}` |
| `GET` | `/api/rooms` | 列表 |
| `POST` | `/api/rooms/<id>/archive` | 归档，邀请码立即失效 |
| `GET` | `/api/join?code=` | 客户端校验邀请码（引导第 5 步，建立 WS 前调用）→ `200 {room:{id,name,director,welcome,guests[],defaultTracks}}` 或 `403 {error:"INVALID_CODE"}`；同 IP 失败 5 次锁 10 分钟 |
| `POST` | `/api/frames?room=&client=&track=` | 客户端上传 JPEG（≤ 300 KB，长边 ≤ 960px）；服务器只保留每轨最新一张于内存，响应 `{url}` |
| `GET` | `/frames/<room>/<client>/<track>.jpg?ts=` | 控制端取静帧 |
| `POST` | `/api/contact-sheets?room=&client=&recording=&track=` | 上传宫格图 JPEG（≤ 4 MB）；服务器落盘保存 7 天 |
| `POST` | `/api/upload/init` | `{room, client, recording, track, bytes, partSize}` → `{uploadId, key, parts:[{n,url}]}` |
| `POST` | `/api/upload/complete` | `{uploadId, key, parts:[{n,etag}], sha256}` → `{ok, downloadUrl}` |
| `GET` | `/api/recordings/<id>/download?track=` | 控制端重新获取预签名下载链接 |
| `GET` | `/download` | 嘉宾下载页（**固定地址，与房间无关**）：按 UA 给 dmg/exe |

## 7. 离线与重连语义

| 情况 | 行为 |
|---|---|
| 客户端断线重连 | 重发 `hello` + 完整 `state`；服务器把离线期间**最后一条** `stop` 或 `finish_task` 补发（其它指令丢弃） |
| 客户端离线时控制端点「开始」 | 服务器直接返回 `ack{ok:false, error:"CLIENT_OFFLINE"}`，不排队 |
| 控制端断线 | 重连后收到完整 `room` 快照 |
| 服务器重启 | 房间、客户端注册、日志在 SQLite；最新静帧丢失（客户端下一个 5 秒周期即恢复） |
| 录制中网络完全不可用 | 录制继续；停止后上传器持续重试；宫格图与成品在网络恢复后补传 |

## 8. 事件码

| code | level | 含义 / 建议处理 |
|---|---|---|
| `DISK_LOW` | warn | 剩余 < 10 GB；控制端黄色 |
| `DISK_CRITICAL` | error | 剩余 < 2 GB；客户端**自动安全停止** |
| `CAM_LOST` / `MIC_LOST` | error | 设备断开；轨道 A 继续录黑场/静音并打标，控制端红色 |
| `FRAME_DROP` | warn | 10 秒内掉帧 > 10% |
| `ENCODER_FALLBACK` | warn | 硬编不可用改软编 |
| `RECORDER_CRASHED` | error | 录制进程异常退出；文件已尽量封口 |
| `PERMISSION_MISSING` | error | 缺权限，附 `detail.permission` |
| `UPLOAD_FAILED` | error | 重试耗尽 |
| `SHEET_FAILED` | warn | 宫格图生成失败 |

## 9. 本地 IPC（UI 进程 ↔ 录制进程）

与上面同一套消息，JSON lines over stdin/stdout：

- UI → Recorder：`start` / `stop` / `snapshot` / `preflight` / `contact_sheet`
- Recorder → UI：`state`（每秒）/ `recording_started` / `recording_stopped` / `event` / `preflight_result` / `snapshot_result{track, path}`

录制进程启动参数：`zsir-recorder serve --output <dir> --quality recommended --cam <id> --mic <id> --display <id> --exclude-window <id>`。UI 进程退出不会关闭录制进程的 stdin 之外的任何东西；录制进程检测到 stdin EOF 时**不退出**，而是继续录制直到：磁盘临界、或看门狗发现 UI 进程超过 60 秒未重连（通过本地 Unix socket / 命名管道重新附着）才 finalize 并退出。

## 10. M2 Relay / 控制端联调约定（issue #8）

- 当前实现 HTTP rooms / archive / join / healthz 与 WS hello / state / countdown / recording_started / recording_stopped / event / ack / start / stop。静帧、上传、下载页和结束任务尚未实现。
- 控制指令的目标为信封顶层 `clientId`（客户端持久化 UUID），昵称为顶层 `operator`（1–80 字符）。服务端校验目标属于当前控制连接的房间，将规范化后的昵称注入转发信封，并记录日志；不会信任消息里声明的其它房间。当前无登录，因此昵称仅用于记录，不是身份认证。
- `start.payload.countdownSec` 必须为 `3`；只接受 `ready` 且在线的嘉宾。`stop` 可随时发送（包括取消倒计时）。客户端应按指令 `id` 幂等处理。
- `ack` 的 `refId` 对应原指令 ID，服务端转发时带顶层 `clientId`，所有当前房间控制端均收到。5 秒未确认返回 `ACK_TIMEOUT`。离线 stop 立即返回 `{refId,ok:true,queued:true}`，表示已保存，**不代表已经停录**。
- 离线 stop 存 SQLite `clients.pending_command`，每个客户端仅保留最新一条。hello 后或同一连接恢复 state 时补发；成功 ack 后清除。进程重启仍保留。失败/未确认可能再次补发，客户端须幂等。离线 start 立即返回 `CLIENT_OFFLINE`，不排队。
- `room` 快照补充 `room.defaultTracks`、`room.archivedAt`、`clients[].countdown`（数字或 null）、`lastSeen`；`lastFrames` 当前为空对象。录制记录含 `recordingId/clientId/startedAt/stoppedAt/tracks/files`。日志含 `id/ts/clientId/actor/level/code/text/detail`，最多最近 200 条。
- 首次有效 state 才算在线；30 秒无 state 标离线（即使仍响应 pong）。断开立即离线。状态向控制端最多广播 1 次/秒，重连快照不受节流限制。
- `/api/rooms` 返回房间数组，包含已过期/归档房间；POST 返回 201。过期/归档房间只读，控制指令返回 `ROOM_INACTIVE`，不主动中断本地录制。
- join 与客户端 WS 握手共用同 IP 失败计数；第五次失败起锁定 10 分钟，锁定期间正确码也拒绝。响应统一 403 `INVALID_CODE`。当前单进程内存计数，重启清零；不信任外部 `X-Forwarded-For`。服务器直接暴露端口时使用真实 socket IP；以后增加反向代理时需显式配置可信代理范围。
- 未知消息类型忽略；已知消息参数或信封无效以 1008 关闭客户端 WS；已知控制指令参数无效返回 `INVALID_COMMAND`。文本帧上限 64 KiB。
