# ADR-002 · 一个仓库两条主线

**日期** 2026-10-21 · **状态** 已采纳

## 决策
- `main`：Codex 实现主线。
- `claude`：Claude 实现主线，功能分支 `cl/<topic>`，PR 合并进 `claude`。
- 两条线互不合并、互不引用；最终由 Billy 择优。

## 理由
同仓库便于对比；两条线从同一个空仓库出发，没有共享代码，互不干扰。

## 备注
功能分支不能命名为 `claude/<topic>`：git 引用不允许 `refs/heads/claude` 与 `refs/heads/claude/x` 共存。
