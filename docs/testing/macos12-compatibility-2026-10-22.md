# macOS 12 兼容版验证记录

> 此文件保留前期开发包的历史验证状态。v0.3.0最终包与发布结果见 [本轮发布验证](v0.3.0-release-2026-10-22.md)。

2026-10-22。版本0.3.0，测试构建2026102202，最低macOS12.3。独立Bundle ID `com.zsir.interview.capture.monterey`，ad-hoc签名，未公证。

## 已通过

- ARM64、x86_64 Release构建；两包file架构、vtool最低系统12.3、Info.plist版本/最低系统/应用标识核验。
- 两包 `codesign --verify --deep --strict`。
- 两包 `--check-permissions`、`--check-recording-ui`；Intel经Rosetta执行。包含不支持系统声音时写入true和读取旧true配置的回归。
- ARM64兼容构建CaptureChecks：三档静音MP4、SIGKILL后恢复且原文件不变、Take锁/异常路径、预览元数据、唯一目录和报告、空输入失败、摄像头/桌面/双路合成输出、4K编码解码、12秒H.264/AAC片段MP4完整解码（媒体时间轴14秒）。
- 默认完整版构建回归：部署目标仍为13，权限自检通过，系统声音默认能力保留。
- 两ZIP完整性和包内Info.plist核验通过，附安装说明、MIT许可和外部SHA256SUMS。

测试发现并修复：兼容版systemAudio属性观察器无条件回写false导致递归；增加只在收到true时回写的条件，并加入旧设置恢复及手动启用的自检。

## 交付

目录：`~/Downloads/庄Sir采访录制助手-macOS12兼容版-20261022/`

- `ZSirCapture-0.3.0-macos12.3-compat.20261022-arm64.zip`
- `ZSirCapture-0.3.0-macos12.3-compat.20261022-x86_64.zip`

## 未验证与限制

没有macOS12实机，未验证旧系统真实授权、摄像头/麦克风、桌面、多屏/旋转、音画同步和长录。Rosetta不能替代Intel旧系统验收。未安装替换正式版、未提交代码、未发布Release。

桌面素材无音轨；摄像头素材保留麦克风。兼容版在新系统也禁用系统播放声音。最低12.3，不支持12.0–12.2。首次使用须先短试录。
