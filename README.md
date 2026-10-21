# 庄Sir采访录制助手

让嘉宾自行录下本地高清摄像头与桌面素材。

**项目已有模拟数据交互原型，macOS 双路采集工程，以及 Windows 桌面与系统声音客户端；尚未通过真实采访验收，不可用于正式采访。**

当前首版已改为**完全本地工具**：嘉宾在右上角小窗选择摄像头、桌面或双路，自行开始、停止并保存。可折叠的缩略图用于确认实际写入画面。无需账号、导演网页或中转服务器。原远程方案与网页原型保留为历史参考。

## 下载预览版

[v0.1.0-preview.1 发布页](https://github.com/billzhuang6569/zsir-interview-assistant/releases/tag/v0.1.0-preview.1)提供 macOS Apple Silicon 与 Windows x64 压缩包。安装步骤与限制见[发布说明](docs/releases/0.1.0-preview.1.md)。两端支持录制计时、15 秒无操作收起为屏幕边缘红圈，点击展开。

## 文档导航

- [产品需求与范围](docs/product.md)：角色、流程、规则、异常与验收。
- [开发设计](docs/development.md)：模块边界、状态机、协议、素材生命周期和安全。
- [技术调查与决策](docs/research.md)：官方资料、候选路线、尚未验证的假设。
- [开发计划与验收矩阵](docs/validation.md)：分阶段交付、实验与发布门槛。
- [前端与交互设计](docs/design/README.md)：双端页面规格、状态文案与视觉探索。

## 当前开发

核心行为与新计划见上方文档。macOS 已有真实双路采集基础，用户已确认短录画质；已实现机位及设备选择、可折叠实时预览、异常恢复副本；继续进行长时间稳定性验证。

[macOS 使用与开发说明](clients/macos/README.md)提供构建、启动、自检和试录步骤。[Windows 使用与开发说明](clients/windows/README.md)提供原生小窗、桌面与系统声音录制及实机自检步骤。Windows 摄像头、真实长录制与正式发行仍待完成。

旧 [交互原型](prototype/README.md)和 [远程方案](docs/archive/remote-v0.2/product.md)仅作历史存档，不是本地版当前交付目标。

## 许可证

[MIT](LICENSE)。仓库内原创文档与设计稿按同一许可证提供；引用的外部官方文档仍归原权利人所有。示意人物与会话数据不代表真实采访记录。
