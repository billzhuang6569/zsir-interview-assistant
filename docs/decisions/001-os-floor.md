# ADR-001 · 系统版本下限：macOS 13+ / Windows 10 1903+

**日期** 2026-10-21 · **状态** 已采纳

## 背景
产品需要在不安装任何驱动的前提下录制「系统声音（不含话筒）」。

## 决策
下限定为 macOS 13 Ventura 与 Windows 10 1903（Build 18362）。

## 理由
- macOS 13 引入 ScreenCaptureKit 的系统音频捕获；更早版本只能靠 BlackHole 等虚拟声卡，嘉宾无法自行配置。
- Windows 10 1903 引入 Windows.Graphics.Capture；WASAPI Loopback 自 Vista 即有。
- 覆盖面：2022 年后所有 Mac、近 5 年几乎所有 Windows 设备。

## 后果
- 低于下限的嘉宾：客户端启动时明确提示不支持并给出替代方案（会议软件自录 + 手机拍摄）。
- Windows 1903–1909 上浮窗无法从录屏中排除（WDA_EXCLUDEFROMCAPTURE 需 2004），文档明示。
