# 03 · 通信协议

所有消息为 UTF-8 JSON；WebSocket 文本帧；二进制（静帧、宫格图）走 HTTP。JSON Schema 在 `protocol/schema/`，三端共用。

## 1. 连接

| 端 | URL | 鉴权 |
|---|---|---|
| 客户端 | `wss://<host>/ws/client?session=<6位码>&client=<uuid>` | 会话码有效即允许；`client` 由客户端首次生成并持久化，重连沿用 |
| 控制端 | `wss://<host>/ws/control?session=<会话 id>` | 当前版本无鉴权（内部使用） |

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

服务器校验会话后原样转发给目标客户端，并把「谁点了什么」写入事件日志广播给所有控制端。

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
| `session` | 完整会话快照：`{session:{id,name,code,createdAt}, clients:[{clientId,name,os,appVersion,online,lastState,lastFrames:{cam:{url,ts},screen:{url,ts}}}], recordings:[…], log:[…最近 200 条]}`，连接时与会话变化时发 |
| `client_state` | `{clientId, state}`（转发） |
| `client_online` / `client_offline` | `{clientId}` |
| `frame` | `{clientId, track, url, ts}` 静帧更新 |
| `log` | `{ts, actor, text, level}` |
| `ack` | 转发客户端回执 |
| 其余客户端上行消息 | 原样转发（带 `clientId`） |

## 6. HTTP 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/sessions` | 控制端新建会话 `{name}` → `{id, code, downloadUrl}` |
| `GET` | `/api/sessions` | 列表 |
| `POST` | `/api/frames?session=&client=&track=` | 客户端上传 JPEG（≤ 300 KB，长边 ≤ 960px）；服务器只保留每轨最新一张于内存，响应 `{url}` |
| `GET` | `/frames/<session>/<client>/<track>.jpg?ts=` | 控制端取静帧 |
| `POST` | `/api/contact-sheets?session=&client=&recording=&track=` | 上传宫格图 JPEG（≤ 4 MB）；服务器落盘保存 7 天 |
| `POST` | `/api/upload/init` | `{session, client, recording, track, bytes, partSize}` → `{uploadId, key, parts:[{n,url}]}` |
| `POST` | `/api/upload/complete` | `{uploadId, key, parts:[{n,etag}], sha256}` → `{ok, downloadUrl}` |
| `GET` | `/api/recordings/<id>/download?track=` | 控制端重新获取预签名下载链接 |
| `GET` | `/download/<code>` | 嘉宾下载页：按 UA 给 dmg/exe，链接内含会话码 |

## 7. 离线与重连语义

| 情况 | 行为 |
|---|---|
| 客户端断线重连 | 重发 `hello` + 完整 `state`；服务器把离线期间**最后一条** `stop` 或 `finish_task` 补发（其它指令丢弃） |
| 客户端离线时控制端点「开始」 | 服务器直接返回 `ack{ok:false, error:"CLIENT_OFFLINE"}`，不排队 |
| 控制端断线 | 重连后收到完整 `session` 快照 |
| 服务器重启 | 会话、客户端注册、日志在 SQLite；最新静帧丢失（客户端下一个 5 秒周期即恢复） |
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
