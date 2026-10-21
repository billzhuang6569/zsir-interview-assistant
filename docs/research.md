# 当前技术路线

首版为完全本地运行的 macOS 工具，沿用 Swift、AVFoundation、ScreenCaptureKit 与 AVAssetWriter；没有服务器、网页控制、登录和上传。旧远程方案的技术调查保留在 [历史调查](archive/remote-v0.2/research.md)，其中云端与卸载方案已不属于当前范围。

采集、编码和文件生命周期的官方依据与已知限制见 [macOS 开发说明](../clients/macos/README.md)。Windows 仍需后续实机评估；长录制、异常恢复和正式发行签名尚未完成。
