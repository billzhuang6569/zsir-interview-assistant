# 技术调查与架构决策

复核日期：2026-10-21。本文区分官方能力、方案推断和实测证据；目前无硬件实测结果。

## 1. 结论

用户已确定“本地原生采集引擎＋多人免登录导演网页＋用户提供服务器的 HTTPS/WSS 中转”。服务器只处理授权、命令、状态和临时预览；部署参数待核对。服务器与云服务不是对立选项：自建服务也可以运行在云主机。

| 路线 | 适配本项目的收益 | 代价 | 当前选择 |
| --- | --- | --- | --- |
| 两端点对点 | 可能减少中转图片流量 | NAT、企业网络、重连与中继复杂度 | 首版不优先 |
| 云主机自建长连接服务 | 可控、可按嘉宾地域部署 | TLS、更新、监控、备份需自己维护 | 已选定：用户提供服务器 |
| 托管长连接＋临时对象存储 | 减少连接基础设施维护 | 地域网络、额度、供应商绑定需验证 | 历史备选，首版不采用 |

两路各 100 KB / 每 5 秒，约 144 MB/小时上传（十进制单位），平均 320 kbps；N个在线网页的图片出口约为144×N MB/小时；例如3人约432 MB/小时，不含协议开销。客户端每周期每机位仍只上传一次，由服务器扇出。高清检查和宫格额外计费。此为预算算式，非账单或实测。预览拥塞时丢弃旧帧并降级预览，不能挤占编码写盘。

## 2. 平台证据与边界

| 需求 | 官方依据 | 可以据此确定 | 仍需实验 |
| --- | --- | --- | --- |
| macOS 屏幕与音频 | [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)、[官方采集示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) | 系统提供屏幕/音频采集与过滤入口 | 所选 OS 上音频、权限、排除小窗与双路编码 |
| Windows 屏幕 | [Windows Graphics Capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture) | 可采集屏幕/窗口帧，需检查支持性并处理用户选择 | 原生集成、缩放、多屏、热插拔 |
| Windows 系统声音 | [WASAPI Loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) | 可录指定播放端点的输出混音 | 输出设备切换、静音、蓝牙/USB、受保护内容限制 |
| Windows 排除控制窗 | [SetWindowDisplayAffinity](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity) | 自有顶层窗口可申请排除；EXCLUDEFROMCAPTURE 在 Windows 10 2004 引入 | 具体录屏与会议捕获路径是否生效，不能视为安全屏障 |
| 托管会话长连接 | [Durable Objects WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/) | 可协调 WebSocket，休眠机制可减少空闲计算开销 | 目标地区可达性、超时/重连、真实价格与负载 |

已读取 Apple 示例页的官方 Markdown；当前示例明确要求 macOS 15+ 和 Xcode 16+，这是该示例的运行要求，不应直接等同于整个产品或 ScreenCaptureKit 的最低版本。官方 API 能力不是“所有设备和会议软件稳定共用”的证明。本文没有据此承诺最低系统版本。对 Windows 也必须使用实际系统、驱动和会议版本建立支持清单。

## 3. 原生采集候选

macOS：Swift / AVFoundation 负责摄像头与话筒；ScreenCaptureKit 负责屏幕与系统音频；系统编码/封装工具负责输出。Windows：C++ 原生采集适配，Media Foundation 处理摄像头/编码，WASAPI 处理音频，Windows Graphics Capture 处理屏幕。语言与 UI 框架待 P0 定案，不先引入跨平台壳。

导演网页可采用 TypeScript＋React；服务拟采用部署在用户服务器上的长连接实现，不以托管对象服务作为首版依赖。当前仓库不安装这些依赖，避免在原生验证前锁定工具链。实施时需固定版本并补版本对应文档。

## 4. 必须先过的实验

1. 摄像头/话筒与腾讯会议、飞书、Zoom 分别测试两种启动顺序，设备切换及重新加入。共享失败时明确告知，不抢占或静默关闭会议。
2. 音频隔离：话筒测试口令和系统测试音分别输入，检查各文件仅含预期主动音轨；声学串音另行记录。
3. 自身小窗排除：本工具视频、过程预览、录后宫格均检查；会议分享单独记录。
4. 两路 2 小时同步：起止同步闪光/声标，测音画和机位间漂移，不只比较系统时钟。
5. 分段/碎片 MP4 对比：强杀、断电、磁盘满、收尾空间不足；测丢失区间与恢复成功率。
6. 在用户服务器上验证真实嘉宾地域网络、多浏览器广播、代理超时与出口容量；不以 API 存在替代网络可达性。

## 5. 决策记录

- ADR-001：原始素材本地优先；中转失联不控制已运行录制的生命周期。
- ADR-002：两套原生适配共享行为规范；不追求一份录屏实现覆盖两个 OS。
- ADR-003：预览来自采集管线；验片宫格来自落盘解码，两类证据不能混用。
- ADR-004：引擎与 UI/网络/抽帧任务隔离；先承担必要复杂度以保护素材。
- ADR-005：H.264/AAC/MP4 是互操作性实验起点，H.265、4K 与多档画质后置。

中转采用用户服务器、多人免登录固定网页及结束任务卸载已获用户明确确认；其余技术路线仍是评审稿中的建议。只有实机证据和项目评审通过后，才升级为发布承诺。

## 6. 卸载可行性与承诺边界

[Apple 卸载说明](https://support.apple.com/en-ie/102610)说明应用可提供专用卸载功能；[Windows Installer 标准命令](https://learn.microsoft.com/en-us/windows/win32/msi/standard-installer-command-line-options)提供卸载及重启控制选项。存在接口并不意味着正在运行的应用一定能静默删除所有组件；权限、文件占用、包类型及系统策略均需实验。

产品目标仍是“结束任务后卸载干净并关闭”，工程实现优先用户级安装、最少后台组件和清单化卸载。不得承诺抹除系统审计/隐私权限历史，不能通过删除原片达到“干净”。需验证保存失败、离线、权限拒绝、文件锁定、卸载器结果回传及自身退出。官方能力不足以确认这些验收已经通过。
