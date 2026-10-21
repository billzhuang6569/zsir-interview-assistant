# macOS v0.1.0 权限引导验收

日期：2026-10-21。环境：macOS 26.6.2（25G83），Apple Silicon，SwiftPM / Command Line Tools。

## 已通过

- `swift run --package-path clients/macos ZSirCapture --check-permissions`：三种模式所需权限；AVFoundation 四种状态映射；拒绝/受限不重复申请；未选权限不读取或请求；请求串行；关闭后的迟到回调不重开；跳过/中断续接；完成后撤权；方式持久化；busy 保护；缺权限不启动采集或创建 Take；两项文案。
- `swift run --package-path clients/macos ZSirCapture --check-recording-ui`：计时、开始写入前不收起、15 秒无操作、重置、展开等待期、异常/停止恢复。
- `swift run --package-path clients/macos CaptureChecks`：独立 Take、原子报告、空采集拒绝成功、单路/双路合成媒体、4K 编码与解码、时钟映射、fragmented MP4、SIGKILL 后副本恢复及原文件保留。
- 独立 review `.app` 的 release 构建与启动；通过原生 UI 自动化和截图验证实际窗口，而非仅阅读代码。
- 首次欢迎页、三种方式与授权卡片布局完整；主界面「摄像头+桌面」未被截断，初始隐私提示与空白行已移除。
- 真实系统已有摄像头/话筒授权被识别；屏幕权限未确认时下一步禁用。
- 摄像头模式只显示摄像头/话筒，两项已授权后进入完成页，点击进入小窗保持“准备就绪 / 尚未录制”，不自动录制。
- 从录制设置进入权限引导成功；完成后切到桌面并点击开始，缺权限时先显示屏幕授权页。
- “打开系统设置”实际跳转到当前系统的“录屏与系统录音”面板；应用返回仍如实显示未确认。没有修改系统隐私开关。
- Escape 可退出引导；界面按钮、状态与方式出现在系统辅助功能树中。
- `bash -n script/build_and_run.sh script/package-macos.sh` 与 `git diff --check` 通过。

## 发布包检查

- arm64 与 x86_64 release 构建通过；`file` 核对为各自 Mach-O 架构。
- 两个包内可执行文件分别通过权限自检与计时/边缘自检；x86_64 通过 Rosetta 执行，非 Intel 真机。
- 两个 `.app` 均通过 `codesign --verify --deep --strict` 与 Info.plist 校验；版本 0.1.0，build 2，bundle identifier 保持原值。

## 未覆盖的真实环境

- 未重置当前用户 TCC，也未新建系统用户；首次系统弹窗的允许/拒绝/受限以及授权后的系统重启要求由模拟回调覆盖，尚未完成全套真实授权回路。
- 未人工完成 VoiceOver 朗读及全键盘遍历；辅助功能树与 Escape 验证不等于完整无障碍验收。
- 本次未做真实摄像头/桌面短录或长采访。合成编码与恢复通过不等于本版本真实采集通过；原版本历史证据仍可在测试目录查阅。
- 没有 macOS 14 或 Intel 物理机器验收；交叉编译/Rosetta 仅证明相应范围。
- 本机 `security find-identity -v -p codesigning` 返回 0 个可用身份；包使用 ad-hoc 签名，未公证。

测试使用独立构建目录，未替换 `/Applications` 内的应用，未向现有录制进程发送停止或退出命令。UI 测试实例使用相同 bundle identifier，因此读取既有系统权限；不能据此声称全新安装验证通过。
