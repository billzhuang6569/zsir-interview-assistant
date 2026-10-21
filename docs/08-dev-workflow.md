# 08 · 协作流程：Claude 统筹，Codex 开发

## 分工

| 角色 | 做什么 | 不做什么 |
|---|---|---|
| **Claude**（本仓库 `claude` 分支的 owner） | 拆 issue、写任务书、派给 Codex、真机验收、code review、合并 PR、部署、维护文档与 ADR | 不直接写业务代码（除文档、配置、一行级修补） |
| **Codex** | 按任务书实现、自测、在 `cl/<task>` 分支提交并开 PR 到 `claude` | 不改任务书范围之外的东西；不合并；不碰 `main` |
| **Billy** | 拍板、提供资源、抽查验收 | — |

## 分支与 PR

- `main`：Codex 独立线，本流程**永不触碰**。
- `claude`：我们的主线，等同 main。只接受 PR 合并，不直接推送。
- 功能分支 `cl/<issue号>-<短名>`，例如 `cl/12-mac-recorder`，从最新 `claude` 切出。
- 一个 issue 一个 PR；PR 标题 `<类型>: <中文一句话> (#issue)`；描述写「做了什么 / 怎么自测的 / 没做什么」。
- PR 由 Claude 验收后合并（squash），合并后删分支。

## 一个任务的生命周期

1. Claude 在 GitHub 建 issue（标签 `milestone:M1` 等），写清「目标 / 范围 / 接口 / 验收标准 / 不要做」。
2. Claude 把 issue 内容整理成任务书，交给 Codex（`/codex:rescue`）。
3. Codex 实现 → 本地构建通过 → 自测 → 推分支 → 开 PR。
4. Claude 真机验收（mac 本机、win 通过 SSH、server 通过 SSH），review 代码。
5. 不过：Claude 把问题写回 PR 评论，Codex 续同一线程修。过：合并、关 issue、更新文档。

## 环境

| 环境 | 用途 | 访问 |
|---|---|---|
| 本机 Mac（macOS 26，仅 Command Line Tools，无 Xcode.app） | macOS 端构建与验收 | 本地。**只能 SwiftPM**（`swift build`），不能用 xcodebuild |
| Windows 测试机（Win11，.NET 8 SDK，Inno Setup，无摄像头） | Windows 端构建与验收 | `ssh skillhub-windows` |
| Relay 服务器（Debian 13，2C/3.6G/40G） | 部署 server + control | `ssh zsir-server` |
| GitHub Actions | 三条流水线：macos / windows / ubuntu | 自动 |

联网命令统一走本机代理 `HTTPS_PROXY=http://127.0.0.1:7897`。

## Definition of Done（每个 PR）

- [ ] 对应 issue 的验收标准逐条写明怎么验的
- [ ] CI 绿
- [ ] 新增/变更的接口同步到 `docs/03` 或 `protocol/schema`
- [ ] 没有引入 issue 没要求的依赖或文件
