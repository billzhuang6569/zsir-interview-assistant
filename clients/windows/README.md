# Windows 本地客户端（开发版）

.NET 8 WinForms 小窗，录制选定显示器和选定播放设备的完整系统声音，不采集摄像头或话筒。默认主显示器和系统当前输出。右上角小窗通过 Windows 显示亲和性排除，预览来自同一桌面采集流的 10 fps 视频支路，可折叠。

## 构建

要求 Windows 10 2004+ / x64，.NET 8 SDK 与 Desktop Runtime，以及独立 FFmpeg/ffprobe 可执行文件。

```powershell
dotnet build clients/windows/ZSirCapture.Windows.csproj -c Release
```

将受信任的 `ffmpeg.exe`、`ffprobe.exe` 放在生成目录 `tools/` 下，再运行 `ZSirCapture.Windows.exe`。开发测试使用此前校验的 FFmpeg 9.0.2 gyan.dev 构建；默认 libx264 软件编码，避免已发现的 NVENC API / 显卡驱动不兼容。

FFmpeg不提交二进制到仓库、不在应用启动时下载。`script/build-windows-tools.sh`从固定FFmpeg/x264源码交叉构建精简x64工具和完整源码包；`script/package-windows.ps1`校验工具压缩包哈希后内置组件，实际编码/探测/解码通过才出包。最终用户完整解压即可离线录制。包内附FFmpeg/x264许可证，Release附源码和构建脚本。见[来源说明](RECORDING-TOOLS.md)。应用尚未签名。

## 录制与保存

- 选择显示器、系统声音输出和素材目录。明确选定的设备不可用时取消启动。
- 点击开始、停止并保存。静音时保留音轨时间，不会把声音前移。
- 每条 Take 独立目录（保留的中间文件会额外占用磁盘）：`desktop.mp4` 为最终 H.264/AAC 视频；`desktop-video.mp4` 和 `system-audio.wav` 是保留的原始中间文件，另有报告和日志。
- 保存阶段复制视频流、编码 AAC；需额外磁盘空间，长录制的保存可能较慢。合成失败不删除分离素材。
- 系统声音采用 WASAPI render endpoint loopback，通过 QPC 时间戳补齐静音并对齐视频起点。RF64 WAV 不受普通 WAV 的 4 GB 长度字段限制。
- `finalized_unverified` 只代表封装及双轨检查完成，仍需听检和 FCP 导入。睡眠、拔设备、写盘失败、系统时间跳变或编码器异常会停止并保留素材。
- 不联网、不安装虚拟声卡、不改驱动。Windows 自动恢复界面和摄像头尚未实现。强杀前尚未写出的片段仍可能丢失。

## 实机测试

```powershell
.\ZSirCapture.Windows.exe --smoke-test C:\path\to\new-unique-test-directory
```

测试会显示背景画面并播放三次低音量测试音，调用与按钮相同的开始/停止路径；检查首条音视频完整解码、三个声音/闪光的时间偏差和静音间隔、连续第二次录制、无效设备拒绝、RF64 时间线，以及主动终止本次测试编码器后的异常提示与原素材保留。结果为 `acceptance.json`。请使用新目录，测试素材会保留。不要对正在正式录制的实例运行测试。

官方依据：[WASAPI loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)、[GetBuffer 时间戳](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer)、[小窗排除](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)。


## 2026-10-21 界面修订

名称统一为“庄Sir采访录制助手”，程序与快捷方式使用 REC / Zsir 图标。暗色渐变面板、暖橙主按钮、深色设备菜单；使用统一的深色标题区域，可拖动、最小化和关闭；Windows 11 请求系统 Acrylic 背景及圆角，内容面板保持深色渐变以保证可读性，实际系统材质受透明效果和 DWM 支持影响。内容高度随布局和预览折叠计算，不再写死折叠高度；停止后的预览注明为上次录制画面。目录打开失败会提示，不再让事件异常退出程序。

`--smoke-test` 额外检查折叠后高度减少、展开恢复、可见按钮没有被窗口裁切，并输出待录、折叠和录制界面截图。未验证所有 DPI、辅助功能模式或 Windows 10 的视觉效果。

## 录制计时与屏幕边缘提示

录制中显示累计时:分:秒；15 秒未操作小窗后自动收起到右侧边缘红圈。点击红圈展开，不影响录制；停止或检测到异常时恢复主窗口。红圈与主窗口均排除出录制，系统关闭动画时红圈保持静止。自检覆盖自动收起、计时增长、展开继续录制、停止及编码器中断后的窗口恢复。

## 按架构打包

```powershell
.\script\package-windows.ps1 -Architecture x64 -ToolsArchive C:\build\recording-tools-win-x64.zip
.\script\package-windows.ps1 -Architecture arm64 -ToolsArchive C:\build\recording-tools-win-x64.zip
```

从仓库根目录运行，输出到 `dist/release/`，目标目录已存在时拒绝覆盖。包自带对应架构的 .NET 运行时及许可。ARM64 包要求 Windows 11 ARM64，应用为原生 ARM64；当前固定版本 FFmpeg/ffprobe 为 x64，依赖系统仿真，尚非全链路原生 ARM 编码。

构建工具链：macOS安装mingw-w64、nasm、pkgconf后运行 `script/build-windows-tools.sh`，产物位于终端打印的构建目录。源码包与六包一起发布。正式打包核对仓库固定哈希，不能随意接受未经审核的二进制。

长录验收：在交互式桌面设置 `ZSIR_SMOKE_SECONDS=1800` 后运行原 `--smoke-test 新目录`，测试音和闪光分布于开头/中段/结尾。测试不修改用户录制设置，不打开摄像头或话筒。默认仍为短录。
