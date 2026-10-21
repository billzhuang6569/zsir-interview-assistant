# 04 · 客户端开发文档（macOS / Windows）

两端共享同一结构：**App（UI 进程）** + **Recorder（录制进程）** + **Shared（协议模型）**。本文先讲共同部分，再讲各平台实现细节。

## 1. 共同结构

```
App（UI 进程）
├─ FloatingPanel        角落浮窗（状态、按钮）
├─ Onboarding           欢迎 / 权限 / 设备 / 自检 / 邀请码 / 欢迎卡
├─ Settings             设备、输出目录、画质、浮窗位置
├─ RecorderBridge       启动/附着录制进程，JSON lines IPC，看门狗
├─ RelayClient          WSS 连接、重连、hello/state 上报、指令分发
├─ FrameUploader        静帧 JPEG 压缩与 HTTP 上传（5 秒节流）
├─ Uploader             成品分片断点续传（独立后台任务）
└─ Uninstaller          结束任务

Recorder（录制进程，无 UI，CLI）
├─ serve                常驻模式：读 stdin 指令
├─ preflight            3 秒试录，输出 JSON
├─ contact-sheet        从文件抽帧拼图
├─ Capture/Screen       屏幕 + 系统声
├─ Capture/Camera       摄像头 + 话筒
├─ Encode               硬编 + 容器写入
├─ Clock                统一时间基
└─ Watchdog             stdin EOF / 磁盘 / 设备监控
```

### 1.1 状态机（App）

```
idle ──权限+设备 ok──► preflight ──全绿──► joining(输邀请码, GET /api/join) ──成功──► ready
                                                  joining ──失败──► joining(行内报错，可重输)
ready ──start(本地/远程)──► countdown(3s) ──► recording
recording ──stop──► stopping(finalize) ──► postprocess(宫格图) ──► uploading ──► ready
任一状态 ──finish_task──► finishing ──► exit
任一状态 ──致命错误──► error（可重试回 preflight）
```

### 1.2 看门狗规则

| 监控点 | 周期 | 动作 |
|---|---|---|
| 录制进程存活 | 1 s | 退出码非 0 → `RECORDER_CRASHED`；UI 自动拉起新进程进入 `error`，**不自动重新开始录制**（避免产生碎片），由导演决定 |
| 磁盘剩余 | 5 s | < 10 GB 警告；< 2 GB 安全停止 |
| 轨道帧率 | 10 s 窗口 | 掉帧 > 10% 警告 |
| 设备热插拔 | 系统事件 | `CAM_LOST` / `MIC_LOST`；轨道继续写（黑场/静音），不中断另一路 |
| UI 进程存活（Recorder 侧） | stdin EOF | 继续录制；60 s 无人重新附着 → finalize 退出 |

### 1.3 静帧抓取

- 录制中：Recorder 每 5 秒把两路最新一帧缩放到长边 960、JPEG q=70 写到 `frames/<track>.jpg`，发 `snapshot_result`；App 上传。
- 非录制中收到 `snapshot`：Recorder 临时打开捕获，抓一帧后立即关闭（保证不录时捕获进程不常驻，兑现隐私承诺）。

### 1.4 宫格图

- 每 30 秒抽一帧，缩放到 320 宽，网格 6 列，每格左下角烧时间码；总高度不限，JPEG q=80。
- 2 小时录制 = 240 格 = 40 行 ≈ 1920×7200，约 3 MB。
- macOS 用 `AVAssetImageGenerator`；Windows 用内置 ffmpeg `select='not(mod(t,30))',scale=320:-1,drawtext,tile=6x0`。

### 1.5 日志

- App 与 Recorder 各自写滚动日志到输出目录 `log.txt`（同一次录制）与应用日志目录；级别 info 以上。
- 每条 `event` 同时写本地日志与上报。
- 「文件」面板提供「上传日志」按钮，打包最近 3 次房间日志到对象存储供排查。

## 2. macOS 实现

### 2.1 工程

- Xcode 15+，Swift 5.9，部署目标 macOS 13.0。
- Swift Package：`App`（SwiftUI + AppKit）、`Recorder`（可执行 target）、`Shared`。
- Recorder 作为 App bundle 内的 helper 可执行文件（`Contents/MacOS/zsir-recorder`），与 App 共享签名与 TCC 身份（**必须**在同一 bundle 内，否则屏幕录制权限要分别授权）。

### 2.2 关键实现点

| 模块 | 实现 |
|---|---|
| 浮窗 | `NSPanel` + `.nonactivatingPanel` + `.hudWindow`；`level = .floating`；`collectionBehavior = [.canJoinAllSpaces, .stationary]`；SwiftUI 内容通过 `NSHostingView` |
| 排除自身 | 启动捕获前取浮窗 `windowNumber`，`SCContentFilter(display:excludingWindows:)`；浮窗位置变化不影响 |
| 屏幕+系统声 | `SCStreamConfiguration`：`width/height` 按档位、`minimumFrameInterval = CMTime(1, fps)`、`capturesAudio = true`、`sampleRate 48000`、`channelCount 2`、`excludesCurrentProcessAudio = true`、`showsCursor = true`；`SCStreamOutput` 分别收 `.screen` 与 `.audio` |
| 摄像头+话筒 | 一个 `AVCaptureSession`，`.inputPriority` preset；`AVCaptureDevice.DiscoverySession` 列设备；格式选 ≤1080p 且 fps≥30 的最高者 |
| 写入 | 每路一个 `AVAssetWriter(outputURL:, fileType: .mov)`，`movieFragmentInterval = CMTime(2,1)`，`shouldOptimizeForNetworkUse = false`；视频 input `outputSettings`：`AVVideoCodecKey: .h264`、`AVVideoProfileLevelKey: H264HighAutoLevel`、`AVVideoAverageBitRateKey`、`AVVideoMaxKeyFrameIntervalDurationKey: 2`；音频 input：AAC 48k 256k |
| 时间基 | `startSession(atSourceTime:)` 两路用同一 `CMClock.hostTimeClock` 时间；记录每路首帧 PTS |
| 防睡眠 | `IOPMAssertionCreateWithName` |
| 权限检测 | `CGPreflightScreenCaptureAccess()`、`AVCaptureDevice.authorizationStatus(for: .video/.audio)`；引导页用 `CGRequestScreenCaptureAccess()` + 打开系统设置深链 |
| 自卸载 | 见 02 文档 §7 |

### 2.3 构建与分发

- CI：`macos-14` runner，`xcodebuild -scheme App -configuration Release archive` → `.app` → `create-dmg`。
- 签名：Developer ID Application 证书（Secrets：`MAC_CERT_P12`、`MAC_CERT_PASSWORD`）；Hardened Runtime 开启；entitlements：`com.apple.security.device.camera`、`.audio-input`。
- 公证：`xcrun notarytool submit --wait` + `stapler`（Secrets：`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`）。
- 未签名的 CI 产物只用于内部测试（右键打开）。

## 3. Windows 实现

### 3.1 工程

- .NET 8，`net8.0-windows10.0.19041.0`（可运行于 1903+，WDA 特性运行时检测）。
- 项目：`App`（WPF）、`Recorder`（Console，自包含发布）、`Shared`。
- 内置 `ffmpeg.exe`（LGPL 构建，含 nvenc/qsv/amf/mf/aac，不含 x264）放 `Recorder/ffmpeg/`，随 Recorder 发布。

### 3.2 关键实现点

| 模块 | 实现 |
|---|---|
| 浮窗 | WPF `Window`：`Topmost`、`WindowStyle=None`、`AllowsTransparency`、`ShowInTaskbar=false`、`ShowActivated=false`；托盘用 `H.NotifyIcon` |
| 排除自身 | `SetWindowDisplayAffinity(hwnd, 0x11 /*WDA_EXCLUDEFROMCAPTURE*/)`；Build < 19041 时返回失败 → 记录警告，浮窗照常显示 |
| 屏幕 | `Windows.Graphics.Capture`：`IGraphicsCaptureItemInterop.CreateForMonitor(hmon)`；`Direct3D11CaptureFramePool.CreateFreeThreaded`（BGRA8，2 buffers）；每帧 `Map` 到 CPU → 写入 ffmpeg video 管道；若捕获分辨率变化（用户改缩放）重建 pool 并记事件 |
| 系统声 | NAudio `WasapiLoopbackCapture`（默认渲染设备）；`DataAvailable` 回调写 audio 管道；**定时器 20 ms 检查，无数据时写等量静音**；设备切换时重新打开 |
| 摄像头 | `MediaCapture` + `MediaFrameReader`（NV12/BGRA）；失败回退 DirectShow（`DirectShowLib`）；话筒 NAudio `WasapiCapture` |
| ffmpeg 调用 | 每路一个 ffmpeg 进程：`-f rawvideo -pix_fmt bgra -s WxH -r 30 -use_wallclock_as_timestamps 1 -i \\.\pipe\zsir_v_<track> -f f32le -ar 48000 -ac 2 -use_wallclock_as_timestamps 1 -i \\.\pipe\zsir_a_<track> -c:v <enc> -b:v <kbps>k -g 60 -c:a aac -b:a 256k -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 2000000 out.mp4`；编码器在 preflight 时探测并缓存 |
| 停止 | 关闭两个管道 → ffmpeg 正常 EOF 收尾 → 等待退出 ≤ 10 s；超时 `kill`（fMP4 仍可用） |
| 防睡眠 | `SetThreadExecutionState` |
| 自卸载 | 见 02 文档 §7 |

### 3.3 构建与分发

- CI：`windows-2022` runner，`dotnet publish -r win-x64 --self-contained -p:PublishSingleFile=true`；Inno Setup 打包 `.exe` 安装包（per-user 安装，无需管理员）。
- 签名：`signtool` + 代码签名证书（Secrets：`WIN_CERT_PFX`、`WIN_CERT_PASSWORD`）；无证书阶段 SmartScreen 会警告，文档明示嘉宾「更多信息 → 仍要运行」。

## 4. 本地开发与测试

| 环境 | 能做什么 |
|---|---|
| Linux 容器（Claude 日常） | server、control、protocol 全量开发与测试；客户端代码编写与静态检查（`swift build` 在 Linux 上可编译 Shared 与非平台代码；`dotnet build` 可编译全部 C#，WinRT 调用需 Windows 运行） |
| GitHub Actions | 两个原生端的真实编译、单元测试、打包、签名 |
| Billy 的 Mac / Win 机器 | 真机验收：权限引导、捕获、会议软件共存、断网、断电测试；通过链接的会话由 Claude 远程执行命令行构建与测试 |

测试矩阵（P2 必过）：

| 维度 | 取值 |
|---|---|
| macOS | 13（Intel）、14（Apple Silicon）、15 |
| Windows | 10 22H2、11 23H2；核显 / NVIDIA / AMD |
| 摄像头 | 内置、USB 1080p、USB 4K、采集卡 |
| 显示器 | 单屏、双屏不同缩放、4K HiDPI |
| 会议软件 | Zoom、腾讯会议、飞书、Teams —— 同时开摄像头 + 共享屏幕 |
| 破坏测试 | 杀 UI 进程、杀 Recorder、拔网线、合盖、拔摄像头、磁盘写满、断电 |

### 4.1 M1 Windows CLI 落地约定

实现与构建/真机脚本见 [client-windows/README.md](../client-windows/README.md)。`devices --json`、`preflight --json [--camera id --mic id --display id]`、`capture --out <dir> [--tracks cam,screen --duration seconds --quality saver|recommended|high]` 与 M1 mac 共用接口；stdout 是 UTF-8 JSON lines，错误为 `errors:["CODE: 说明"]` 字符串数组。

`session.json` 公共字段为 `version/state/startedAt/clock/hostTimeT0/devices/quality/encoder/t/tracks/levels/error`，每路含 `ok/width/height/fps/targetFPS/bytes/levelDb/audioSamples/droppedSamples/firstPTS/firstFrameOffsetMs`。Windows 的 `hostTimeT0` / `firstPTS` 使用 QPC 秒；捕获源预热后从共同 T0 输出 CFR，首帧输出偏移为 0；音频按 QPC 放入 PCM 时间缓冲，静音补零。ffmpeg 以固定帧率和样本数产生 PTS，**不以管道到达墙钟做时间戳**。正常结束标记 `finished`，错误标记 `failed`，强杀保留最后一个原子写入的 `recording` 快照。

Windows CLI 必须运行在交互桌面，OpenSSH Session 0 直接捕获会报 `INTERACTIVE_SESSION_REQUIRED`；远程验收用 `/IT` 计划任务。窗口排除测试只检查隐藏窗口上的 API 返回值，视觉效果需后续独立验收。LGPL 编码兜底明确使用 `h264_mf -hw_encoding 0` 并报告 `ENCODER_FALLBACK`；不使用 x264。M1 不包含设备热插拔恢复、DirectShow 回退或显示器尺寸变化后的自动重建。
