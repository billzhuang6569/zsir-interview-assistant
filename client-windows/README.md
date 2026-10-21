# Windows Recorder · M1

离线 .NET 8 CLI。屏幕使用 Windows.Graphics.Capture，系统声使用 WASAPI loopback；摄像头使用 MediaCapture/MediaFrameReader，话筒使用 WASAPI。每路一个 ffmpeg 子进程，命名管道传 BGRA 和 48 kHz 双声道 float PCM，输出 H.264 High + AAC fragmented MP4。

## 构建

```powershell
# 已从 Mac 下载归档时，无需 Windows 联网：
powershell -ExecutionPolicy Bypass -File scripts/fetch-ffmpeg.ps1 -Archive C:\path\ffmpeg.zip
dotnet build -c Release
dotnet run --project Recorder.Tests -c Release -- --encoder-smoke
dotnet publish Recorder -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish
```

下载脚本固定 BtbN LGPL 归档和 SHA-256；支持以 `HTTPS_PROXY` 指定下载代理，不更改系统代理。Mac 下载：

```sh
HTTPS_PROXY=http://127.0.0.1:7897 curl -fL \
  https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-20-13-08/ffmpeg-n8.1.3-18-g46d899d7a0-win64-lgpl-8.1.zip \
  -o /tmp/zsir-ffmpeg.zip
scp /tmp/zsir-ffmpeg.zip skillhub-windows:C:/zsir/ffmpeg.zip
```

`publish/zsir-recorder.exe` 是自包含单文件，旁边必须保留 `ffmpeg/` 目录（含 ffmpeg.exe、ffprobe.exe、LICENSE.txt、BUILD.txt）。二进制不提交 Git。BtbN 完整包较大，尚未做发行包裁剪；此阶段不制作安装包。

## CLI

```powershell
.\publish\zsir-recorder.exe devices --json
.\publish\zsir-recorder.exe preflight --json
.\publish\zsir-recorder.exe capture --out C:\recordings\take-001 --tracks screen --duration 600
.\publish\zsir-recorder.exe capture --out C:\recordings\take-002 --tracks cam,screen --camera '<id>' --mic '<id>' --display '<id>' --quality recommended
```

- 与 issue #6 相同的命令和字段；摄像头参数是 `--camera`。`devices` 只枚举，不开启采集。
- capture 必须提供 `--out`，目录已有 cam.mp4/screen.mp4/session.json 或另一个录制进程占用时拒绝写入。`--tracks screen` 不打开摄像头或话筒。
- 未指定时长时一直录制，Ctrl+C / Ctrl+Break 优雅停止。Windows 的 `taskkill /F` 是强杀，依靠已落盘的 fMP4 fragments 恢复；没有 Unix SIGTERM 语义。
- stdout 为 UTF-8 JSON：devices/preflight 一个对象；capture 每秒 `{t,tracks:{screen:{fps,bytes}},levels}`；诊断与 ffmpeg 日志写 stderr。正常退出 0，错误退出 1；preflight 无摄像头时保留 screen 试录结果并返回 CAM_NOT_FOUND。
- preflight 试录 3 秒，自动清理其独有临时目录。`levelDb=-120` 表示静音；`systemAudio.ok` 表示捕获和写入链路成功，不表示系统正在播放声音。
- 编码器依次实际试编码 NVENC → QSV → AMF → MF hardware → MF software。软编报告 ENCODER_FALLBACK 并降一档。不会引入 GPL x264。

## 时间轴与安全

所有捕获源预热到首帧后，以一个 `Stopwatch.GetTimestamp()`（Windows QPC）作为 T0。视频按 QPC 固定帧率采样，音频按同一 QPC 放入有时间位置的缓冲，每 20 ms 写出，静音位置补零。ffmpeg 以样本数生成 PTS，不使用管道到达的墙钟时间，避免两个 pipe 的调度延迟改变同步关系。原生摄像头/桌面帧较慢时重复最新画面。

`session.json` 与同仓库 mac M1 工作区的公共字段保持一致：version/state/startedAt/clock/hostTimeT0/devices/quality/encoder/t/tracks/levels/error。每路含 ok/width/height/fps/targetFPS/bytes/levelDb/audioSamples/droppedSamples/firstPTS/firstFrameOffsetMs。每秒原子更新，结束标 finished，失败标 failed；强杀后保留最后的 recording 快照。`firstPTS` 使用 QPC 秒，`firstFrameOffsetMs` 是输出流首帧相对共同 T0 的偏移（CFR 两路均为 0）。音频 callback 到达时间近似原始采集时间，真机双路音画同步仍需用波形验收。错误数组与 mac 相同，使用 `CODE: 可读说明` 字符串。

每 2 秒写 fragment，正常停止关闭管道并等 ffmpeg 收尾。输出空间 <2 GiB 时安全停止并报 DISK_CRITICAL；编码管道落后 15 秒报错退出，保留现有文件。录制期间请求系统保持唤醒。隐藏测试窗口仅验证 WDA_EXCLUDEFROMCAPTURE API 调用成功，视觉排除仍须单独验收。

## 真机测试

必须在**已登录的交互桌面**启动。OpenSSH 默认处于 Session 0，能枚举设备，但屏幕捕获会报 INTERACTIVE_SESSION_REQUIRED。可用 `schtasks /Create ... /RU administrator /IT` 建临时交互任务执行脚本，并通过 SSH 读取输出；验完删该任务。无需改服务。

```powershell
# 播放低音量测试音，验证真正的系统回环；不使用虚拟声卡作为录制依赖。
powershell -ExecutionPolicy Bypass -File scripts/smoke.ps1 -Recorder C:\zsir\issue7-publish\zsir-recorder.exe -Output C:\zsir\smoke-600 -Duration 600 -PlayTone
# 强杀 Recorder，检查 ffmpeg 收到 pipe EOF 后退出且文件仍可解析。
powershell -ExecutionPolicy Bypass -File scripts/smoke.ps1 -Recorder C:\zsir\issue7-publish\zsir-recorder.exe -Output C:\zsir\smoke-kill -Duration 60 -KillTest
```

脚本验证设备/无摄像头诊断、ffprobe 时长和 codec、完整音视频解码、播放测试音时的非静音音频。CPU 统计包含 Recorder + 直属 ffmpeg 子进程，除以逻辑核数；脚本保留全部输出和统计 result.json。

边界：尚无 UI/网络/上传/安装包/serve；没有摄像头 DirectShow 回退。录制中显示器/摄像头尺寸变化会报错停止（不自动重建格式），音频设备切换也需停止重启；这些恢复行为留给后续稳定性阶段。Windows 1903/1909 无窗口排除能力，Win10 与其他 GPU 的兼容性需分别真机验收。
