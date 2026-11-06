# Windows 本地客户端（开发版）

.NET 8 WPF 小窗，支持「摄像头」「桌面」「摄像头+桌面」三种机位。旧设置默认继续使用桌面录制；摄像头配话筒，桌面配选定播放设备的完整系统声音。默认主显示器、第一台可用摄像头、系统默认录音设备与系统当前输出。右上角小窗默认通过 Windows 显示亲和性排除，每路预览来自同一采集流的 10 fps 视频支路，可折叠。

## 构建

要求 Windows 10 2004+ / x64，.NET 8 SDK 与 Desktop Runtime，以及独立 FFmpeg/ffprobe 可执行文件。

```powershell
dotnet build clients/windows/ZSirCapture.Windows.csproj -c Release
```

将受信任的 `ffmpeg.exe`、`ffprobe.exe` 放在生成目录 `tools/` 下，再运行 `ZSirCapture.Windows.exe`。必须使用本仓库配套工具包（含 DirectShow、MJPEG/rawvideo 解码与 `select@preview` 门控补丁）；普通 FFmpeg 构建无法通过门控检查。桌面沿用硬件探测与有界 libx264 回退，摄像头使用 libx264、8 Mbps、CFR 30 与 AAC 192k。

FFmpeg不提交二进制到仓库、不在应用启动时下载。`script/build-windows-tools.sh`从固定FFmpeg/x264源码交叉构建精简x64工具和完整源码包；`script/package-windows.ps1`校验工具压缩包哈希后内置组件，实际编码/探测/解码通过才出包。最终用户完整解压即可离线录制。包内附FFmpeg/x264许可证，Release附源码和构建脚本。见[来源说明](RECORDING-TOOLS.md)。应用尚未签名。

## 录制与保存

- 在主窗选择机位；设置页按机位显示摄像头/话筒和桌面卡片。选择设备和素材目录，选项立即保存。明确选定的设备不可用时取消启动，不自动切换；高级设置「重新检测设备」刷新列表。摄像头保存 DirectShow alternative name，重名设备仍可独立选择。
- 点击开始、停止并保存。静音时保留音轨时间，不会把声音前移。
- 每条 Take 独立目录（保留的中间文件会额外占用磁盘）：`desktop.mp4` 和/或 `camera.mp4` 为最终 H.264/AAC 视频。保留 `desktop-video.mp4`、`system-audio.wav` 和/或 `camera-video.mp4`、`microphone.wav`；系统声音关闭时桌面成品仅含视频。`report.json` 记录机位、摄像头稳定 ID/名称/格式、话筒名称、各轨起点与成品列表。双路任一路失败都会停止整个 Take 并保留原始素材。
- 保存阶段复制视频流、编码 AAC；需额外磁盘空间，长录制的保存可能较慢。合成失败不删除分离素材。
- 系统声音采用 WASAPI render endpoint loopback；话筒使用 capture endpoint（默认 eConsole）。两者复用 QPC 时间戳、补齐静音与 RF64 写入管线，各自按 FFmpeg 视频 Unix 起点对齐。RF64 WAV 不受普通 WAV 的 4 GB 长度字段限制。
- `finalized_unverified` 只代表封装及双轨检查完成，仍需听检和 FCP 导入。睡眠、拔设备、写盘失败、系统时间跳变或编码器异常会停止并保留素材。
- 不联网、不安装虚拟声卡、不改驱动。高级设置支持手动扫描并恢复未完成素材的副本（目前扫描恢复桌面轨道；摄像头原始素材保留，可手工合成）。强杀前尚未写出的片段仍可能丢失。

## 实机测试

```powershell
.\ZSirCapture.Windows.exe --smoke-test C:\path\to\new-unique-test-directory
```

测试会显示背景画面并播放三次低音量测试音，调用与按钮相同的开始/停止路径；检查首条音视频完整解码、三个声音/闪光的时间偏差和静音间隔、连续第二次录制、无效设备拒绝、RF64 时间线，以及主动终止本次测试编码器后的异常提示与原素材保留。结果为 `acceptance.json`。请使用新目录，测试素材会保留。不要对正在正式录制的实例运行测试。

官方依据：[WASAPI loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)、[GetBuffer 时间戳](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer)、[小窗排除](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)。


## 界面与 DPI

主窗按 Mac 布局重排为 336 逻辑像素宽、16 逻辑像素内边距：标题与关闭、状态与说明、录制计时、机位选择、可折叠实时预览、开始/停止按钮与目录/设置图标。三机位仅在空闲时可切换，双路预览左右显示「摄像头 · 话筒」与桌面。主窗收起预览、最小化、隐藏或开始录制前会释放空闲摄像头；打开设置后由设置页接管摄像头采集和话筒电平，关闭/离开该页即释放。预览标注是否包含系统声音；保存位置、设备重新检测和恢复入口移至设置的高级页。关闭按钮退出程序；托盘「显示小窗」可恢复收起或最小化的小窗。

`Theme.xaml` 统一视觉稿中的暗色令牌与控件模板；`MainWindow`、`SettingsWindow` 和 `EdgeWindow` 分别承载主窗、设置两页和边缘提示。`MainViewModel` 保存可绑定状态，`RecordingController` 管理录制、预览释放、健康检查和恢复；录制引擎保持原样。主窗宽 336 DIP，双路预览 16:10、单路 16:9，支持系统减少动画。Win11 22621+ 使用 Mica 与圆角，较早系统回退到深色实底。通过 manifest 启用 PerMonitorV2；WinForms 仅保留托盘、文件夹选择和屏幕枚举互操作；`CaptureVisibility` 改接 HWND，`GlobalUsings.cs` 为原引擎保留 `Screen` / `Rectangle` 类型别名。

`--smoke-test` 保留原有 desktop / camera / both / noCamera 录制阶段、媒体、解析器、资源租约、恢复和隐身检查。WPF 在 `UpdateLayout` 后检查可见元素的父级边界和 Panel 同级重叠（显式标记的叠加层除外），滚动区域按完整画布检查并逐项滚动确认交互控件可见；主窗各状态、设置两页以 root `LayoutTransform` 执行 1 / 1.25 / 1.5 / 2 倍布局检查。使用 `RenderTargetBitmap` 输出 `client-ready.png`、`client-recording.png`、`client-collapsed.png`、`client-nocamera.png`、`settings-main.png`、`settings-advanced.png` 和 `edge-indicator.png`。模拟不能替代 Windows 10/11 实机的 100/125/150/200% DPI、跨屏拖动、图标字体回退与辅助功能验收。

## 录制计时与屏幕边缘提示

录制中显示累计时:分:秒；15 秒未操作小窗后自动收起到右侧边缘半圆底座和呼吸红点。点击红点展开，不影响录制；停止或检测到异常时恢复主窗口。默认红圈与主窗口均排除出录制，系统关闭动画时红圈保持静止。自检覆盖自动收起、计时增长、展开继续录制、停止及编码器中断后的窗口恢复。

## 按架构打包

```powershell
.\script\package-windows.ps1 -Architecture x64 -ToolsArchive C:\build\recording-tools-win-x64.zip
.\script\package-windows.ps1 -Architecture arm64 -ToolsArchive C:\build\recording-tools-win-x64.zip
```

从仓库根目录运行，输出到 `dist/release/`，目标目录已存在时拒绝覆盖。包自带对应架构的 .NET 运行时及许可。ARM64 包要求 Windows 11 ARM64，应用为原生 ARM64；当前固定版本 FFmpeg/ffprobe 为 x64，依赖系统仿真，尚非全链路原生 ARM 编码。

构建工具链：macOS安装mingw-w64、nasm、pkgconf后运行 `script/build-windows-tools.sh`，产物位于终端打印的构建目录。源码包与六包一起发布。正式打包核对仓库固定哈希，不能随意接受未经审核的二进制。

长录验收：在交互式桌面设置 `ZSIR_SMOKE_SECONDS=1800` 后运行原 `--smoke-test 新目录`，测试音和闪光分布于开头/中段/结尾。测试不写回用户录制设置。未启用合成摄像头时不录制摄像头或话筒；设备枚举与格式检查可能短暂初始化设备。默认仍为短录。

## 在录屏里隐身与托盘

「在录屏里隐身」默认开启，旧设置自动沿用开启状态。空闲时可在录制设置或系统托盘菜单切换，立即作用于主窗、边缘红点和设置窗；录制、保存和恢复期间禁止切换。开启时远程协助和会议共享看不到小窗，排除失败会阻止开始录制。关闭后远程端可看到并操作小窗，但小窗也会进入桌面录制；每次开始前会确认，15 秒无操作仍收起为边缘红点。`report.json` 的 `stealthInCapture` 记录本次状态。

托盘支持显示小窗（双击亦可）、开始录制 / 停止并保存、打开素材目录和退出。Windows 自带远程桌面（mstsc）表现需实测，不做保证。发行包说明改为带 UTF-8 BOM 的 `README.txt`，打包会拒绝非 ASCII 文件或目录名；FFmpeg 文本输出统一按 UTF-8 解码。


## 摄像头权限与诊断

读取当前用户 `CapabilityAccessManager\ConsentStore` 下 webcam / microphone 及其 NonPackaged 的 Value。任一为 Deny 时提示「Windows 隐私设置禁止桌面应用使用摄像头/麦克风」；仅点击提示或设置页按钮才打开对应系统隐私页，不自动修改权限。被会议软件占用时会提示释放摄像头；拔线会停止并保留素材。注册表缺失/无法读取不等于权限获准，最终以设备实际打开结果为准。

无摄像头的测试机可运行：

```powershell
$env:ZSIR_FAKE_CAMERA = '1'
.\ZSirCapture.Windows.exe --smoke-test C:\tests\camera-new-directory
Remove-Item Env:ZSIR_FAKE_CAMERA
```

纯选项/设备解析检查也可单独运行 `--check-settings`，不启动采集。

合成源只在 `--smoke-test` 生效：摄像头为 lavfi `color`（1280×720、30 fps），话筒为写入同一 RF64 路径的合成 440 Hz 测试音，不打开真实摄像头或话筒。原桌面测试音/闪光流程保留。额外检查中文/重名设备与格式解析、三机位 × 1/1.25/1.5/2 布局、单摄像头和双路各约 8 秒、H.264/AAC/时长/完整解码/报告，以及摄像头编码器异常时整体停止和原素材保留；临时关闭 fake 后，无真实摄像头必须以中文提示拒绝且不创建 Take（有真实摄像头则记录该项跳过）。

真实硬件诊断（使用全新目录）：

```powershell
.\ZSirCapture.Windows.exe --device-check C:\tests\device-new-directory
```

输出 `devices.json`（摄像头与可用格式、话筒、两层隐私状态、峰值与错误）。仅存在话筒时录默认话筒约 3 秒到 `mic-check.wav`；仅存在摄像头且可选择格式时录约 3 秒无声画面到 `camera-check.mp4`。诊断不修改录制选项，fake 环境变量在此模式无效。不要在正式录制期间运行。

本次代码未在 macOS 环境编译或执行 Windows smoke；真实摄像头格式、隐私拒绝、占用/拔线、双路长录同步及 FCP 导入仍需 Windows 实机验收。
