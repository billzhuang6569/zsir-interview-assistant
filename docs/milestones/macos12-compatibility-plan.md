# macOS 12 独立兼容版开发计划

2026-10-22。用户要求优先开发并交付 Intel、Apple Silicon 两包。#24/#26 暂停；不发布正式 Release，不提交代码。

## 范围

- 最低 macOS 12.3（ScreenCaptureKit 起始版本），不支持12.0–12.2。
- 摄像头+麦克风、桌面画面、多屏缩略图、质量档位、权限引导、保存和恢复保留。
- 独立兼容构建在所有系统上均禁用系统播放声音。仅桌面录制无音轨；双路时仅 camera.mp4 带麦克风声音。不开麦克风给桌面混音、不安装虚拟音频驱动。
- 同一源码通过编译标记区分兼容包，默认13+完整构建继续保留系统声音。兼容包使用独立Bundle ID和应用名，不污染完整版本设置；素材目录可继续共享但Take名唯一。

## 步骤

1. 参数化现有构建脚本，兼容构建目标12.3、独立应用标识/版本；SwiftPM最低基础12.3。
2. 编译审计全部13+ API，隔离音频配置和输出、设备类型、SwiftUI/AppKit新接口。时钟转换维持AVCaptureSession.synchronizationClock（SDK标注12.3可用）。
3. UI、默认设置、录制入口、容量估算、报告均基于同一系统声音能力；旧配置为true也不能启用不支持的采集。权限文案适配系统偏好设置。
4. 复用13适配的缩略图流/尺寸/旧渲染和短片段恢复。12专属兼容包在新系统也走旧路径，便于基础逻辑回归。
5. 两架构Release构建、包内最低系统和架构校验、权限/UI检查、合成静音桌面封装与恢复回归；最终ZIP附说明、许可和SHA256。

## 交付与边界

Downloads独立目录内包含两个ZIP，标为macOS12.3+兼容测试版，应用版本0.3.0、独立测试构建号，不替换v0.2.0正式资产。
当前没有12真机；新系统执行旧代码路径及Rosetta仅证明基础运行，不能声称12设备录制/授权/长录已验收。ad-hoc签名，未公证。首片目标短间隔的磁盘开销、音画同步、缩放/旋转、多屏、自窗口排除须旧机短试录后再用于实际采访。

## 完成状态（2026-10-22）

上述开发和本机可执行检查已完成，两架构ZIP已交付下载目录。macOS12实机验收仍未完成。详细证据见[验证记录](../testing/macos12-compatibility-2026-10-22.md)。

复现构建：

```sh
MACOS12_COMPAT=1 BUILD_ARCH=arm64 CONFIGURATION=release APP_BUNDLE="$PWD/dist/macos12-arm64/庄Sir采访录制助手（macOS12兼容版）.app" ./script/build_and_run.sh --build-only
MACOS12_COMPAT=1 BUILD_ARCH=x86_64 CONFIGURATION=release APP_BUNDLE="$PWD/dist/macos12-intel/庄Sir采访录制助手（macOS12兼容版）.app" ./script/build_and_run.sh --build-only
```

## 后续常规发布决定

2026-10-22用户确认以后每次完整发布固定包含此兼容版的Intel/M两个包，跟随统一版本；由 #28 与 #26 落实六包流水线。本兼容版本轮不加入自动检测。此前“不发布正式Release”指本地测试包交付动作，不代表永久排除常规发布。
