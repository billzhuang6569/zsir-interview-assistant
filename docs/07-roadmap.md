# 07 · 路线图

| 阶段 | 目标 | 范围 | 验收 |
|---|---|---|---|
| **P0 · 技术验证** | 证明录制核心在两平台可行，拿到真实码率/体积/CPU 数据 | `client-macos/Recorder`、`client-windows/Recorder` 的 CLI：`capture` 两路、`preflight`、排除自身窗口、fragmented 输出；CI 能产出可运行的二进制 | 在 Billy 的 Mac 与一台 Windows 上各录 10 分钟，文件导入达芬奇正常；强杀进程后文件可用 |
| **P1 · 内部可用** | 团队内部采访可实战 | Relay 服务 + 控制端（新建房间、状态、检查、开始/停止、5 s 静帧、事件日志）；两端 App：浮窗、权限引导、设备选择、自检、邀请码与欢迎卡、本地/远程开始停止；GitHub Actions 全链路构建 | 一次真实内部采访全程用它录；01 §7 第 1–3 条 |
| **P2 · 对外可用** | 给外部嘉宾用 | 宫格图、分片续传 + 校验、文件面板、结束任务、签名与公证、下载页、多显示器、低配降档 | 01 §7 全部 6 条；测试矩阵全过 |
| **P3 · 打磨** | 稳定版 | 多嘉宾房间、HEVC 选项、对齐哔声、日志一键上传、控制端访问令牌、英文界面 | 连续 10 场外部采访零事故 |

## 本分支的下一步

1. `cl/protocol-schema`：`protocol/schema/*.json` + 三端共享类型。
2. `cl/server-skeleton`：Relay 服务可跑通 hello/state/指令转发，含测试。
3. `cl/control-skeleton`：控制端按设计稿实现，用 mock 客户端联调。
4. `cl/mac-recorder-p0`、`cl/win-recorder-p0`：录制 CLI + CI 构建。
5. 真机验证 → 进入 P1。

Billy 需要提供的东西（按先后）：

| 时间点 | 需要 |
|---|---|
| P0 开始 | 一台 Mac（macOS 13+）与一台 Windows 10/11 的真机测试权限（通过已链接的会话执行） |
| P1 开始 | 服务器（域名、SSH）；对象存储桶与密钥 |
| P2 开始 | Apple Developer 账号（Developer ID 证书 + 公证）；Windows 代码签名证书 |
