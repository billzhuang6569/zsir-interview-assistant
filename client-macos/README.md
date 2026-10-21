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

首次采集会请求 TCC 授权；摄像头/话筒各最多等 5 秒，未授权输出 `PERMISSION_CAMERA` / `PERMISSION_MIC`。屏幕权限请求后立即报 `PERMISSION_SCREEN`，授权后重新运行。CLI 内嵌用途说明 Info.plist，M2 App bundle 的签名与权限身份见下方本地 App 章节。沙箱或无图形会话可能枚举不到设备，这不代表真机没有设备。

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

M1 CLI 不实现 UI、网络、serve IPC、上传、宫格图、重连或热插拔补黑场/补静音（M2 本地 UI 见下文）。设备丢失、长时间无帧等完整稳定性策略留给后续里程碑；当前流错误/写入错误会安全停止并返回失败。

## M2 本地 App（issue #14）

```sh
HTTPS_PROXY=http://127.0.0.1:7897 scripts/make-app.sh
open '.build/庄Sir线上采访助手.app'
HTTPS_PROXY=http://127.0.0.1:7897 Tests/run-app.sh
```

`make-app.sh` 用 SwiftPM release 构建并组装 `.app`（可传第一个参数指定产物路径），内置同级 `Contents/MacOS/App` 和 `recorder`，`LSUIElement=true`，写入相机/话筒用途说明并 ad-hoc 签名。使用 `--disable-sandbox` 关闭 SwiftPM 自身的嵌套构建沙箱，**不会改变宿主 Codex 沙箱或网络配置**。可用 `ZSIR_BUILD_DIR` 指定构建缓存目录。没有安装包、公证、网络功能或新增依赖。

首次运行依次显示欢迎/隐私、权限、设备预览、M1 自检；第 5–6 步为 M4 占位，可直接本地使用。设备页和设置页打开时临时预览，离开或录制前关闭；自检复用原始 `preflight --json`（推荐档、两路 3 秒），额外验证选定输出目录可写。自检页缩略图明确标注为设备页最后预览，**不是本次 preflight 产物**；M1 preflight 删除临时文件，未扩展其接口。

浮窗 280×96，非激活、置顶、可拖动、跨空间，记录坐标；屏幕布局改变后若位置不可见，回到主屏右上角。菜单栏可显示浮窗、打开设置/目录、退出。设备、画质、范围、输出目录及引导完成状态保存在 `work.zsir.interview` UserDefaults。初次引导完成前不启动录制；录制中锁定设置、退出前要求先停止并完成保存。

默认输出 `~/Movies/庄Sir采访/<YYYYMMDD-HHMMSS>/`，独占创建子目录，同秒目录碰撞拒绝开始；不覆盖旧文件。3 秒倒计时后启动 recorder，停止二次确认后发送 `stop\n`，等待进程退出再提示保存完成。stdout JSON lines 驱动状态，stderr 和 JSON 状态写入该次 `log.txt`。非零退出显示红色 `RECORDER_CRASHED`，不会自动重录。

### stdin 控制与 App 崩溃

```sh
.build/release/recorder capture --stdin-control --out /tmp/new-session
# 向其 stdin 写入一行 stop，然后等待 exit 0 / finalize。
```

`--stdin-control` 仅适用于 capture；其他参数及无该参数的 CLI 行为不变。未知行忽略，部分行等待换行，超长行丢弃。stdin EOF 表示 UI 断开：继续录制 **60 秒** 后安全停止；stdout 读端消失不会因 SIGPIPE/EPIPE 杀死 recorder。**本阶段不实现重新附着**。重开 App 读取会话标记与 `session.json`，提示后台收尾并阻止新录制，直到旧进程完成；异常文件提供目录检查提示。

### 本阶段测试边界

`Tests/run-app.sh` 无需摄像头，断言 JSON 分片、控制参数、真实子进程 stop/EOF/断开 stdout、桥接退出顺序与非零退出、状态转换、配置保存、目录写入、恢复、倒计时。完整 UI 模型流程用明确的假 recorder 子进程；EOF 单测缩短为 0.3 秒，生产值为 60 秒。它们不证明真实媒体文件完整或 GUI/TCC 通过。

真机仍需 Claude 验收：六步流程和权限归属、预览和音量、1 分钟两路文件、强杀 UI 后续写及 60 秒 finalize/重开提示、浮窗位置和各状态、设备/设置跨进程持久化。自身录屏沿用 recorder 父进程链排除；所有 App 窗口设置 `sharingType = .none`，但 Zoom/腾讯会议的实际隐藏效果必须独立抽查。防睡眠沿用 recorder 的 `PreventUserIdleSystemSleep` 断言，不能用代码存在代替息屏/合盖测试，也不宣称它能覆盖所有系统强制睡眠情形。
