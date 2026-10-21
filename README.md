# 庄Sir线上采访助手

一个极轻量的本地录制工具：嘉宾在自己电脑上安装一个小客户端，把 **摄像头+话筒** 和 **桌面+系统声音** 分别录成两条高清视频；导演在网页控制端远程开始/停止、随时查看静帧、录完检查宫格图，并通过对象存储取回成品。

> 本分支（`claude`）是 Claude 独立实现的主线，与 `main`（Codex 实现）完全独立。两条线并行推进，最终按实际可用性择优。

## 为什么要做它

线上会议软件（Zoom / 腾讯会议 / 飞书）只会输出一条压制合并后的录像，拿不到嘉宾摄像头和桌面各自的高清独立画面，也无法把话筒和系统声音分轨。后期剪辑需要的是：

| 轨道 | 画面 | 声音 |
|---|---|---|
| A | 嘉宾摄像头（原生分辨率） | 嘉宾话筒 |
| B | 嘉宾桌面（原生分辨率） | 嘉宾电脑的系统声音（不含话筒） |

两条文件时间对齐，直接拖进达芬奇 / Premiere / FCP。

## 组成

```
嘉宾电脑                      你的服务器                       导演
┌──────────────────┐        ┌──────────────────┐        ┌────────────────┐
│ 客户端 (Mac/Win)  │◄─WSS──►│ Relay 中转服务    │◄─WSS──►│ 控制端网页      │
│ 角落小浮窗 + 录制 │        │ 状态 / 指令 / 静帧 │        │ 多人同时在线    │
└────────┬─────────┘        └──────────────────┘        └───────▲────────┘
         │ 成品分片直传                                          │ 下载
         └──────────────► 对象存储 (S3 兼容) ◄──────────────────┘
```

## 仓库结构（`claude` 分支）

```
docs/                 产品与开发文档（从 docs/README.md 开始读）
design/               UI 设计稿（HTML 高保真线框，浏览器直接打开）
protocol/             客户端 ↔ 服务器 ↔ 控制端 的消息定义（JSON Schema）
server/               Relay 服务（Node.js + TypeScript）            [P1]
control/              控制端网页（React + Vite）                    [P1]
client-macos/         macOS 客户端（Swift / SwiftUI）               [P0]
client-windows/       Windows 客户端（C# / .NET 8 / WPF）           [P0]
.github/workflows/    CI：三端构建、打包                            [P1]
```

带 `[Px]` 的目录随对应阶段创建，见 [docs/07-roadmap.md](docs/07-roadmap.md)。

## 文档入口

- [docs/README.md](docs/README.md) — 文档索引
- [docs/01-product-design.md](docs/01-product-design.md) — 产品设计（做什么、给谁用、每个按钮的行为）
- [docs/02-architecture.md](docs/02-architecture.md) — 技术架构与选型
- [docs/03-protocol.md](docs/03-protocol.md) — 通信协议
- [docs/04-client.md](docs/04-client.md) — 客户端开发文档（macOS / Windows）
- [docs/05-server-and-control.md](docs/05-server-and-control.md) — 服务端与控制端开发文档
- [docs/06-stability-and-privacy.md](docs/06-stability-and-privacy.md) — 稳定性、安全与隐私清单
- [docs/07-roadmap.md](docs/07-roadmap.md) — 开发路线图
- [docs/decisions/](docs/decisions/) — 关键决策记录（ADR）

## 分支与协作约定

| 分支 | 用途 |
|---|---|
| `main` | Codex 实现主线，本分支不触碰 |
| `claude` | Claude 实现主线，受保护，只接受 PR 合并 |
| `cl/<topic>` | Claude 的功能分支，PR 目标为 `claude` |

> 功能分支不能叫 `claude/<topic>`：git 不允许 `claude` 和 `claude/…` 两种引用同时存在，所以用 `cl/` 前缀。

## 许可

MIT，见 [LICENSE](LICENSE)。
