# 05 · 服务端与控制端开发文档

## 1. Relay 服务（`server/`）

### 1.1 栈

Node.js 20 · TypeScript · Fastify（HTTP + 静态托管控制端）· `ws` · `better-sqlite3` · `@aws-sdk/client-s3`（S3 兼容）· `pino` 日志 · Docker。

### 1.2 目录

```
server/
  src/
    index.ts            启动：Fastify + ws 升级
    config.ts           环境变量读取与校验
    ws/hub.ts           连接注册表：room → {clients, controls}
    ws/clientHandler.ts 客户端消息处理（hello/state/event/ack…）
    ws/controlHandler.ts控制端消息处理（指令转发 + 日志）
    http/rooms.ts    房间 CRUD
    http/frames.ts      静帧上传（内存）/ 读取
    http/sheets.ts      宫格图上传（磁盘）
    http/upload.ts      multipart 预签名 init/complete + 校验
    http/download.ts    下载页（按 UA 返回 dmg/exe）
    store/db.ts         SQLite schema 与查询
    storage/s3.ts       对象存储封装
  test/                 vitest：hub 转发语义、离线补发、上传流程（用 MinIO 容器）
  Dockerfile
  docker-compose.yml    relay + caddy（自动 HTTPS）
```

### 1.3 数据模型（SQLite）

```sql
rooms   (id TEXT PK, name, code TEXT UNIQUE, director, welcome, guests_json, default_tracks, created_at, expires_at, archived_at NULL)
clients    (id TEXT PK, session_id, name, os_json, app_version, first_seen, last_seen)
recordings (id TEXT PK, session_id, client_id, started_at, stopped_at, tracks_json)
files      (id PK, recording_id, track, bytes, duration_ms, sha256, object_key, upload_state, uploaded_at)
events     (id PK, session_id, client_id NULL, ts, actor, level, code, text, detail_json)
```

静帧只在内存（`Map<roomId/clientId/track, {buf, ts}>`），进程重启即空。

### 1.4 转发语义（必须有测试覆盖）

- 控制端指令 → 目标客户端在线：转发并等待 `ack`（超时 5 s 给控制端合成 `ack{ok:false, error:"ACK_TIMEOUT"}`）。
- 目标离线：`start/snapshot/set_quality` 立即拒绝；`stop/finish_task` 记入 `pending_command`（每客户端只保留最新一条），客户端 `hello` 后补发。
- 所有指令写 `events` 并广播 `log`。
- 客户端 `state` 节流：对控制端广播最多 1 条/秒/客户端。

### 1.5 配置（环境变量）

| 变量 | 说明 |
|---|---|
| `PORT` | 默认 8080 |
| `PUBLIC_URL` | 对外 https 地址，用于生成下载链接 |
| `DB_PATH` | SQLite 路径 |
| `S3_ENDPOINT` / `S3_REGION` / `S3_BUCKET` / `S3_ACCESS_KEY` / `S3_SECRET_KEY` | 对象存储 |
| `S3_PRESIGN_TTL` | 预签名有效期，默认 24h |
| `SHEET_DIR` | 宫格图落盘目录 |
| `CLIENT_DMG_URL` / `CLIENT_EXE_URL` | 当前版本安装包地址（GitHub Releases 或对象存储） |

### 1.6 部署

- 单台 VPS，`docker compose up -d`：`relay` + `caddy`（反代 + 自动证书）。
- 资源：1 vCPU / 1 GB 足够 10 个并发房间。
- 备份：每日 `sqlite3 .backup` 到对象存储。
- 对象存储生命周期：成品 30 天后转低频/归档（可配置），宫格图 7 天删除。

## 2. 控制端（`control/`）

### 2.1 栈

React 18 · Vite · TypeScript · Zustand（状态）· 无 UI 框架（自写 CSS，设计稿见 `design/`）。

### 2.2 页面与组件

```
src/
  main.tsx
  App.tsx               顶栏 + 左栏房间列表 + 主区
  ws.ts                 WebSocket 连接、重连、消息分发到 store
  store.ts              room / clients / log / 本人昵称
  pages/RoomPage.tsx
  components/
    RoomHeader.tsx   名称、导演、邀请码（大字+复制）、「复制邀请文案」
    ClientCard.tsx      状态、两路静帧、指标、按钮组
    FramePair.tsx       两路静帧 + 「x 秒前」时效颜色
    TrackMeter.tsx      分辨率/帧率/码率/电平
    CountdownOverlay.tsx
    ContactSheetDialog.tsx
    FilesDialog.tsx     文件、上传进度、下载、SHA、复制手动拷贝文案
    ConfirmDialog.tsx   停止 / 结束任务 二次确认
    EventLog.tsx
    NewRoomDialog.tsx   房间名 / 导演 / 嘉宾姓名(多) / 欢迎语 / 默认录制范围
```

### 2.3 交互规则

- 首次打开要求填昵称（存 `localStorage`），之后所有指令带 `operator`。
- 按钮点击 → 立即进入「发送中」态 → 收到 `ack` 才恢复；`ack{ok:false}` 以行内红字显示错误码对应的中文。
- 静帧「x 秒前」每秒重算；> 15 s 黄、> 30 s 红。
- 倒计时：收到 `countdown` 后在卡片上覆盖大数字，和嘉宾端同步。
- 页面标题随状态变化（`● 录制中 00:14:32 · 张三`），方便导演在多标签页间看一眼。
- 断线：顶栏变红「与服务器断开，重连中…」，所有按钮禁用。

### 2.4 构建

`vite build` 输出到 `server/public/`，由 Relay 托管；CI 在 `ubuntu` 上构建并与 server 一起打 Docker 镜像。

## 3. 下载页（`/download`，固定地址）

Relay 直接渲染的极简静态页，**不带任何房间参数**，所有嘉宾用同一个地址：

- 自动识别 macOS / Windows，大按钮下载对应安装包；另一平台小链接。
- 三步图示：安装 → 允许权限并检查画面 → 输入导演给的邀请码。
- 不做「链接自动带码」（URL scheme / 安装包改名那套）：多一条链路就多一个现场翻车点，6 位数字嘉宾手输 5 秒钟的事。
- 隐私承诺三条（见 06 文档 §2）。
