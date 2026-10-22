# macOS 13 兼容开发检查

> 此文件保留前期开发包的历史验证状态。v0.3.0最终包与发布结果见 [本轮发布验证](v0.3.0-release-2026-10-22.md)。

日期：2026-10-22；基线 v0.2.0。关联 [Issue #25](https://github.com/billzhuang6569/zsir-interview-assistant/issues/25)。

用户明确当前没有 macOS 13 测试机，本轮先完成开发与构建检查。代码未提交，未发布，也未替换已有运行应用或正式安装；当前公开 v0.2.0 仍要求 macOS 14+。

## 实现

- Package.swift、构建 target triple、Info.plist 最低系统统一为 13.0。
- macOS 14+ 保留 filter.contentRect × pointPixelScale；13 从显示模式像素尺寸及显示器方向取得输出尺寸，共用偶数尺寸校验供编码和缩略图使用。
- 13 缩略图使用低分辨率、无音频 SCStream，排除本应用。首个完整帧、错误、取消、3秒等待超时仅完成一次，随后停止并移除输出；停止设置预览会取消并等待该任务。超时限制首帧等待，系统 startCapture/stopCapture 的响应时间并不由此保证。
- 13 设备枚举使用 externalUnknown/builtInMicrophone 等可用类型，按唯一ID去重。
- 13 预览使用 AVSampleBufferDisplayLayer 自身的入队/刷新接口；14+保留 sampleBufferRenderer。
- 两个 SwiftUI onChange 回调改用13可用签名。
- 14+ 保持首片1秒/后续10秒；13无 initialMovieFragmentInterval，改为统一目标1秒片段，以保留早期恢复机会。实际片段落盘仍受关键帧/编码器影响，写入开销需13实测。

## 已通过

验证主机：macOS 26.6.2 Apple Silicon。Intel检查通过Rosetta执行，不是Intel物理机。

- arm64-apple-macosx13.0 和 x86_64-apple-macosx13.0 SwiftPM Debug构建、独立.app打包，无编译警告/错误。
- 两架构 Mach-O LC_BUILD_VERSION minos=13.0、Info.plist LSMinimumSystemVersion=13.0；file核对架构、codesign --verify --deep --strict通过。
- 两架构 --check-permissions：旧版尺寸计算（Retina、非Retina、5K、旋转、奇数尺寸、非法尺寸）、首帧先于等待/等待中完成、失败、超时、取消及迟到回调检查；现有权限、持久化和开始前门禁检查。
- 两架构 --check-recording-ui：录制时间码、边缘收起、错误恢复、权限浮窗不遮挡位置检查。
- ARM64 CaptureChecks：三档无音轨封装及恢复；原文件保留、活动Take锁、SIGKILL恢复、符号链接输入排除、共享预览不污染样本、单/双路合成素材、4K编码和解码、12秒音视频/14秒时间线完整解码。
- git diff --check。

## 未验证

当前机器运行14+分支；部署目标13并不会把系统变成13。上面的纯逻辑检查直接调用旧版算法/完成状态，但没有开启13真实屏幕流、旧版预览渲染或1秒片段写入分支。仍需macOS13 ARM和Intel设备验证：权限流程、摄像头/系统声音、原像素/旋转/混合DPI、自窗口排除、预览停止、媒体首尾同步、热插拔、至少30分钟资源/磁盘开销及异常恢复。

不将此次结果描述为macOS13完整支持验收，也不调整公开Release下载要求。#25保留open待真机验收。

## 本地开发产物

- dist/compatibility/macos13-arm64/庄Sir采访录制助手.app
- dist/compatibility/macos13-x86_64/庄Sir采访录制助手.app

产物仍带基线版本号0.2.0，仅作未发布开发检查，不能覆盖/上传已有v0.2.0资产；正式发布版本在未来发布授权时统一处理。
