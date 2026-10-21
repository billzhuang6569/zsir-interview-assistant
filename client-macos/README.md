# macOS Recorder — M1 / issue #6

纯 SwiftPM、macOS 13+，仅系统框架；Command Line Tools 即可，无需 Xcode.app。

```sh
HTTPS_PROXY=http://127.0.0.1:7897 swift build -c release
.build/release/recorder devices --json
.build/release/recorder preflight --json
.build/release/recorder capture --out /tmp/interview-001 --duration 600
.build/release/recorder capture --out /tmp/screen-001 --tracks screen --duration 10
```

保留 M0 的 `Recorder` 产品名，新增小写 `recorder` 同入口。所有运行时 stdout 都是 JSON lines；系统框架诊断可能出现在 stderr。失败 exit 1；正常时长到期、SIGINT、SIGTERM finalize 后 exit 0。参数校验失败也输出 `errors`。

`capture` 支持 `--camera id --mic id --display id --tracks cam,screen --duration 秒 --quality saver|recommended|high`。不指定 duration 持续录制直到信号停止。`preflight` 支持三个设备 ID，固定推荐档、两路 3 秒试录到唯一临时目录，结束后删除。`devices` 不打开捕获或请求权限。显示器 ID 是字符串，尺寸为物理像素。

首次采集会请求 TCC 授权；摄像头/话筒各最多等 5 秒，未授权输出 `PERMISSION_CAMERA` / `PERMISSION_MIC`。屏幕权限请求后立即报 `PERMISSION_SCREEN`，授权后重新运行。CLI 内嵌用途说明 Info.plist，未来 App bundle 的签名与权限身份由 M2 处理。沙箱或无图形会话可能枚举不到设备，这不代表真机没有设备。

每个输出目录写 `cam.mp4`、`screen.mp4`（仅选中轨道）和 `session.json`。任一同名成品已存在就拒绝，避免覆盖。H.264 High 硬编为必需条件，不静默改软编；AAC 48kHz 双声道 256kbps。MP4 每 2 秒写 fragment、每 2 秒关键帧，实际掉电/kill 恢复须真机验证。输出默认档严格使用推荐码率；低分辨率摄像头按支持的最高 ≤1080p30 格式，高档上限 4K30。

两路先预热，收到视频后取共同 host-clock T0；摄像头 sample 时间从 AVCaptureSession.synchronizationClock 转为 host clock。duration 从 T0 起算，文件 finalize 时间另计。`session.json` 每秒原子更新，含版本、设备名、尺寸、targetFPS/实测平均 fps、首帧 host PTS、相对 T0 的 `firstFrameOffsetMs`、排除应用 PID、状态和错误。音量为最近音频 buffer 的峰值 dBFS（静音 -120）。`systemAudio.ok` 表示收到音频样本，不代表有可听声音。

排除规则：ScreenCaptureKit 排除 recorder 及父进程链上所有可共享应用（含宿主终端）的所有窗口；不是只排除某个终端 tab。通过任务启动器/守护进程启动、终端不是祖先进程时无法自动识别终端；请直接在要排除的终端运行验收。系统声排除 recorder 自身音频。`--tracks screen` 不枚举/打开相机或话筒。

## 无 XCTest 自测（CLT 可运行）

```sh
Tests/run.sh
# 无媒体服务的沙箱仅运行逻辑断言（明确跳过编码测试）
Tests/run.sh --logic-only
```

断言检查参数、档位、已有文件保护，并用合成视频+静音 PCM 测试实际硬件编码器、MP4 fragment、音视频轨及 6 秒时长；打印 `SYNTHETIC_OUTPUT` 供 ffprobe。合成样本测试不能替代真实设备/权限/音画同步验收。`ZSIR_TEST_LONG=1 Tests/run.sh` 会生成 60 秒合成内容，可用于中途 kill 测试，输出保留在临时目录。

## Claude 真机验收

1. `preflight --json`，确认 errors 为空；播放可听音频并对话筒说话。
2. 新目录 `capture --duration 600`；ffprobe 两路应为 H.264/AAC、600±1 秒；比较 `tracks.*.firstFrameOffsetMs` 差值与波形（<100ms）。
3. 新目录持续 capture，10 秒后 `kill -9 <PID>`；ffprobe 和 QuickTime 播放两路，确认只丢最后几秒。
4. 录制时 Activity Monitor CPU <25%；`--tracks screen` 菜单栏无摄像头绿点。
5. 从终端直接启动，检查 screen.mp4 不含该终端窗口；检查 `excludedApplicationPIDs`。
6. 分别 SIGINT、SIGTERM；检查 exit 0、session.state=finished、两路文件可解析。

本阶段不实现 UI、网络、serve IPC、上传、宫格图、重连或热插拔补黑场/补静音。设备丢失、长时间无帧等完整稳定性策略留给后续里程碑；当前流错误/写入错误会安全停止并返回失败。
