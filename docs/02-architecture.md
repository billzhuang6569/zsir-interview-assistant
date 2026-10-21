# 02 · 技术架构

## 1. 拓扑

```
┌────────────────────────── 嘉宾电脑 ──────────────────────────┐
│                                                              │
│  UI 进程（浮窗 / 托盘 / 设置 / 看门狗）                          │
│     │  本地 IPC（JSON lines over stdio）                        │
│     ▼                                                        │
│  录制进程 zsir-recorder（独立可执行文件，无 UI）                   │
│     ├─ 轨道 A: 摄像头 + 话筒  ──► 硬件 H.264 + AAC ──► cam.*     │
│     └─ 轨道 B: 屏幕 + 系统声  ──► 硬件 H.264 + AAC ──► screen.*  │
│                                                              │
│  上传进程（停止后启动，分片断点续传）──────────────────┐          │
└────────────┬─────────────────────────────────────────┼──────────┘
             │ WSS 控制通道 + HTTPS 静帧                 │ HTTPS 分片直传
             ▼                                         ▼
     ┌─────────────────┐                      ┌──────────────────┐
     │  Relay 服务      │                      │  对象存储 (S3 兼容) │
     │  Node.js + ws    │                      │  OSS / COS / R2   │
     │  内存态 + SQLite  │                      └────────▲─────────┘
     └────────▲────────┘                               │ 预签名下载
              │ WSS                                     │
     ┌────────┴────────────────────────────────────────┴────┐
     │  控制端网页（React）× N 人                              │
     └──────────────────────────────────────────────────────┘
```

两条原则决定了上面所有箭头的方向：

1. **录制本地优先**。录制进程不知道网络的存在。UI 进程负责把指令翻译成本地 IPC，把状态翻译成网络消息。网络断了，UI 进程照常驱动录制进程。
2. **UI 与录制进程分离**。UI 崩溃 → 看门狗（录制进程内置）继续写盘直到文件封口；录制进程崩溃 → UI 立即报警到两端，并且 fragmented 容器保证已写入的内容可用。

## 2. 技术选型

| 组件 | 选型 | 理由 |
|---|---|---|
| macOS 客户端 | Swift 5.9 / SwiftUI + AppKit（浮窗）；录制进程纯 Swift CLI | 系统音频捕获只有 ScreenCaptureKit 不需要虚拟声卡；VideoToolbox 硬编；AVAssetWriter 原生支持分段写入 |
| Windows 客户端 | C# / .NET 8 / WPF；录制进程 C# CLI + 内置 ffmpeg（LGPL 构建） | Windows.Graphics.Capture + WASAPI Loopback 是唯一不装驱动就能拿系统声音的组合；编码与封装交给 ffmpeg，一次覆盖 NVENC / QSV / AMF / Media Foundation 四种硬编 |
| Relay 服务 | Node.js 20 + TypeScript + `ws` + Fastify；SQLite 持久化会话；Docker 部署 | 流量极小，单进程足够；与控制端共享类型定义 |
| 控制端 | React 18 + Vite + TypeScript，静态文件由 Relay 服务托管 | 无登录、无路由复杂度；一个 SPA |
| 对象存储 | 任意 S3 兼容（阿里 OSS / 腾讯 COS / Cloudflare R2） | 服务端只签发预签名 multipart URL，大文件不经过 VPS |
| 协议 | WebSocket + JSON，HTTP 上传二进制 | 见 03 文档，JSON Schema 放在 `protocol/` |
| CI | GitHub Actions：`macos-14` 构建 Swift，`windows-2022` 构建 .NET，`ubuntu` 构建 server/control | Claude 在 Linux 容器中开发，原生端的编译与打包全部在 CI 上完成；签名用仓库 Secrets |

### 为什么不是 Electron / 纯 ffmpeg / libobs

| 方案 | 致命问题 |
|---|---|
| Electron + MediaRecorder | macOS 上系统音频捕获不可靠；输出 WebM/VP9 导入剪辑软件体验差；崩溃时文件完整性无保障；包体 150 MB+ |
| 纯 ffmpeg 命令行捕获 | macOS avfoundation 无系统音频（需 BlackHole）；Windows 无 WASAPI loopback 输入（需「立体声混音」或虚拟声卡） |
| 嵌入 libobs | 能力最全、最稳，但包体 100 MB+、启动慢、浮窗 UI 需自己接 C API；团队无 C++ 能力时维护成本高。保留为 Plan B |

## 3. 录制核心原理

### 3.1 macOS（`client-macos/Recorder`）

| 步骤 | API | 要点 |
|---|---|---|
| 枚举显示器与窗口 | `SCShareableContent` | 过滤掉自身窗口 |
| 屏幕画面 | `SCStream` + `SCContentFilter(display:excludingWindows:[自身浮窗])` | 自身窗口从捕获源头排除；`minimumFrameInterval` 设 1/30 或 1/15；`queueDepth` 5 |
| 系统声音 | 同一 `SCStream`，`SCStreamConfiguration.capturesAudio = true`，`excludesCurrentProcessAudio = true` | macOS 13+ 原生，不含话筒；48 kHz 2ch |
| 摄像头 | `AVCaptureSession` + `AVCaptureVideoDataOutput` | 选设备支持的最高 ≤1080p30 格式；允许 4K 选项 |
| 话筒 | `AVCaptureAudioDataOutput` | 与摄像头同一 session，保证 PTS 同源 |
| 编码 | `AVAssetWriter` + `AVAssetWriterInput`（`AVVideoCodecType.h264`，`expectsMediaDataInRealTime = true`） | 走 VideoToolbox 硬编；Profile High，`AVVideoAverageBitRateKey` 按档位 |
| 容器 | `.mov`（QuickTime），`movieFragmentInterval = 2 s` | 每 2 秒落一个完整 fragment，崩溃最多丢 2 秒；停止时正常 finalize |
| 防睡眠 | `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` | 录制期间持有 |
| 权限 | TCC：Screen Recording、Camera、Microphone | 首次启动引导；`CGPreflightScreenCaptureAccess()` 检测 |

### 3.2 Windows（`client-windows/Recorder`）

| 步骤 | API | 要点 |
|---|---|---|
| 屏幕画面 | `Windows.Graphics.Capture`（`GraphicsCaptureItem.CreateForMonitor` via `IGraphicsCaptureItemInterop`） + `Direct3D11CaptureFramePool` | Win10 1903+；`IsCursorCaptureEnabled` 可选；帧回读到 CPU 后以 BGRA 喂 ffmpeg |
| 自身窗口排除 | `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` | Win10 2004+ 生效，顺带让浮窗在会议软件共享中隐身；1903/1909 上浮窗会出现在录屏里（文档明示） |
| 系统声音 | WASAPI Loopback（NAudio `WasapiLoopbackCapture`） | 48 kHz 2ch float；**静音时不产生样本**，必须按时钟补零样本，否则音画漂移 |
| 摄像头 | `Windows.Media.Capture.MediaCapture` 或 DirectShow（兼容老驱动） | 优先 MediaCapture，失败回退 DirectShow |
| 话筒 | WASAPI 采集（NAudio `WasapiCapture`） | 48 kHz |
| 编码 + 封装 | 内置 ffmpeg（LGPL 构建）子进程，两个命名管道分别喂 rawvideo 和 pcm | 编码器探测顺序：`h264_nvenc` → `h264_qsv` → `h264_amf` → `h264_mf`（Media Foundation，所有 Win10 可用）；`-movflags +frag_keyframe+empty_moov+default_base_moof` 输出 fragmented MP4 |
| 防睡眠 | `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)` | |

> 为什么 Windows 不直接用 Media Foundation Sink Writer：MF 的 H.264 编码器在不同显卡厂商驱动上行为差异大，错误信息晦涩；ffmpeg 一次封装四种硬编并有软编兜底，且 fMP4 封装成熟。代价是多一个 ~25 MB 的二进制。

### 3.3 两路对齐

- 录制进程收到 `start` 后取一次单调时钟 `T0` 与墙钟 `W0`，两路编码器同时开启；每路第一帧的 PTS 相对 `T0` 的偏移写入 `session.json`。
- 两路各自内部音画同步靠同源 PTS（macOS：同一 capture session；Windows：所有样本统一打上 `Stopwatch` 时间戳再喂 ffmpeg，`-use_wallclock_as_timestamps 1`）。
- 可选「对齐哔声」：开始时在话筒轨和系统声轨各插一段 1 kHz 100 ms 的正弦（系统声轨通过本机播放一声实现，话筒自然录到），后期可用波形对齐做保险。

### 3.4 自检（Preflight）

录制进程提供 `preflight` 子命令：试录 3 秒两路到临时目录 → 输出 JSON：各路分辨率/帧率/实际码率、音频峰值、编码器名称、写入速度、磁盘剩余、权限状态。UI 据此渲染绿/黄/红。

## 4. 画质档位

| 档位 | 摄像头 | 屏幕 | 合计体积/小时 |
|---|---|---|---|
| 省空间 | 1080p30 · 6 Mbps | 原生分辨率（最大 1920 宽）· 15 fps · 5 Mbps | ≈ 5 GB |
| **推荐（默认）** | 1080p30 · 10 Mbps | 原生分辨率（最大 2560 宽）· 30 fps · 10 Mbps | ≈ 9 GB |
| 高 | 设备最高 ≤ 4K30 · 20 Mbps | 原生分辨率 · 30 fps · 16 Mbps | ≈ 16 GB |

- 视频：H.264 High Profile，VBR，关键帧间隔 2 秒（与 fragment 对齐）。
- 音频：AAC-LC 48 kHz 立体声 256 kbps（话筒轨为单声道复制到双声道，避免剪辑时声像问题）。
- HEVC 作为「高」档的可选项（体积 −40%），默认关闭。
- 无硬编时：降一档并改用软编（macOS 无此情况；Windows 用 `libx264 -preset veryfast`，**仅 LGPL 构建不含 libx264 时退到 `h264_mf`**）。

## 5. 浮窗不被录进去 / 不影响会议

| 平台 | 机制 | 效果 |
|---|---|---|
| macOS | `SCContentFilter` 排除自身窗口 ID | 自己的录屏里没有浮窗；会议软件共享屏幕时浮窗**仍可见**（它们用自己的捕获），但 280×96 置于角落影响可忽略 |
| Windows ≥ 2004 | `WDA_EXCLUDEFROMCAPTURE` | 自己的录屏、会议软件共享里都看不到浮窗 |
| 两端 | 浮窗 `NSPanel`(nonactivating) / WPF `ShowActivated=false`、无通知音、不弹模态 | 不抢会议软件焦点 |

## 6. 成品上传

1. 停止录制 → 录制进程 finalize 文件 → UI 进程启动上传器。
2. 上传器向 Relay 请求 `POST /upload/init`，Relay 调用对象存储 `CreateMultipartUpload`，返回每片（16 MB）的预签名 URL。
3. 分片直传对象存储；本地记录已完成分片（`upload.state.json`），断网/重启后续传。
4. 全部完成 → `POST /upload/complete` 附本地 SHA-256 → Relay 调 `CompleteMultipartUpload` 并从对象存储核对 ETag/大小 → 控制端显示 ✓ 与预签名下载链接（24 小时有效，可重新生成）。
5. 带宽控制：默认不限速；嘉宾可在浮窗暂停上传。

## 7. 结束任务（自卸载）

| 平台 | 步骤 |
|---|---|
| macOS | 停止捕获 → 断开 WSS → 删除 `~/Library/Application Support/ZsirInterview/`、`~/Library/Logs/ZsirInterview/`、`~/Library/Preferences/com.zsir.interview.plist`、LaunchAgent（若有）→ 用 `/bin/sh -c "sleep 1; rm -rf '/Applications/庄Sir采访助手.app'"` 脱离进程执行 → 退出 |
| Windows | 停止捕获 → 断开 → 删除 `%LOCALAPPDATA%\ZsirInterview\` 与注册表 `HKCU\Software\ZsirInterview` → 写一个 `cleanup.cmd`（`timeout 2 & rmdir /s /q <安装目录>` + 自删）→ 以分离进程启动 → 退出 |
| 两端 | 输出目录默认保留，弹一次性提示告知路径；用户可勾选同时删除 |

## 8. 仓库内模块划分

```
protocol/
  schema/*.json            每种消息一个 JSON Schema
  README.md                消息总表（与 docs/03 一致）
server/
  src/ws/                  连接管理、房间、广播
  src/http/                静帧上传、上传凭证、下载链接
  src/store/               SQLite：会话、客户端、事件日志
  src/storage/             S3 兼容客户端封装
control/
  src/pages/Session.tsx    主页面
  src/components/ClientCard.tsx
  src/components/ContactSheetDialog.tsx
  src/ws.ts                客户端连接与状态同步
client-macos/
  App/                     SwiftUI + AppKit 浮窗、设置、权限引导、IPC、WSS
  Recorder/                纯 Swift CLI：capture / preflight / contact-sheet
  Shared/                  协议模型（Codable）
client-windows/
  App/                     WPF 浮窗、设置、IPC、WSS
  Recorder/                C# CLI：capture / preflight / contact-sheet，内置 ffmpeg
  Shared/                  协议模型
```

UI 进程 ↔ 录制进程的本地 IPC 采用与网络协议**同一套消息**（JSON lines），这样网络层只是转发，不需要两套语义。
