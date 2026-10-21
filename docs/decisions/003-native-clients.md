# ADR-003 · 客户端原生实现

**日期** 2026-10-21 · **状态** 已采纳

## 决策
macOS 用 Swift（ScreenCaptureKit / AVFoundation / AVAssetWriter），Windows 用 C#（Windows.Graphics.Capture / WASAPI / 内置 ffmpeg 编码）。不用 Electron、不用纯 ffmpeg 捕获。

## 理由
见 docs/02-architecture.md §2。核心：系统音频捕获在两个平台都只有原生 API 能做到免驱动；硬件编码与崩溃可恢复容器需要底层控制；包体与资源占用要小到不影响会议软件。

## 代价
两套客户端代码。功能面窄（录两路、传静帧、上传），可接受。

## 替代方案
嵌入 libobs：保留为 Plan B，当原生实现遇到无法解决的设备兼容性问题时启用。
