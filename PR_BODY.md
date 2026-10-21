# feat: 实现房间 Relay 与导演控制端 (#8)

目标分支：`claude`；工作分支：`cl/8-relay-control`。Refs #8。

## 做了什么

- HTTP 建房/列表/归档/邀请码校验/健康检查。6 位随机码、7 天有效，join 与客户端 WS 共用同 IP 失败 5 次锁 10 分钟。
- Fastify + ws + SQLite 四表，控制端 start/stop 路由、昵称日志、双端广播、5 秒 ack 超时、30 秒无 state 离线、10 秒 ping / 20 秒无 pong 断开。仅最后一条离线 stop 持久化补发，成功 ack 后清除；覆盖未 ack 再次重连及同连接恢复 state。
- 完整 room 快照、录制元数据与日志持久化；同 UUID 换房清理旧待发指令，旧录制/日志仍留在原房间。
- React 深色监视器页面：昵称持久化、房间列表、新建弹层、邀请码/邀请文案复制、嘉宾状态/时长/范围选择、停止二次确认、倒计时、事件日志及 WS 自动重连。静帧明确标注占位。HTTP 非安全上下文使用复制降级。
- 可直接运行的 mock 客户端：hello、2 秒心跳、3 秒倒计时、start/stop ack、模拟录制、自动重连。
- Docker 多阶段构建与 SQLite 命名卷，无固定域名；托管 `control/dist`。同步 docs/03、docs/05 与 envelope 字段说明。

## 怎么自测

实际使用 **Node v20.20.2** 验证（本机默认 Node 24，另装临时 Node 20；未修改系统 Node 或代理配置）。

```sh
cd server
HTTPS_PROXY=http://127.0.0.1:7897 npm test
# tests 10
# pass 10
# fail 0
# skipped 0

cd ../control
HTTPS_PROXY=http://127.0.0.1:7897 npm run build
# vite v6.4.5 building for production...
# ✓ 28 modules transformed.
# dist/assets/index-CzWY4Mtl.js 155.78 kB │ gzip: 51.20 kB
# ✓ built in 292ms
```

10 项测试涵盖 healthz、建房→mock WS→start→ack/倒计时/录制→两个控制端、stop/录制文件元数据、30 秒 state 超时、离线 start 拒绝/最后 stop 补发、ack 超时、跨房间拒绝、无效消息、同 IP 锁定/解锁/归档/过期、SQLite 重启恢复、HTTP/WS 共享锁、连续重连、换房清理、静态托管。超时测试使用可注入时钟/缩短 ack 时间，未伪称等待了真实 10 分钟。

实际浏览器自测（Chrome 两个独立控制连接/标签页，同一电脑）：

1. 从 UI 填昵称、新建「双导演联调」与两位嘉宾，获得邀请码。
2. Node 20 运行 `npm run mock -- <code> ws://127.0.0.1:18080`，两页都看到在线/就绪。
3. 「自测李导」点击开始，两页均出现数字 3 与倒计时，随后录制中；页面标题/时长更新。
4. 刷新第二页，room 快照恢复录制中。
5. 第二页改名「自测王导」，点击停止并确认，两页均恢复就绪；日志分别显示李导开始、王导停止及客户端完成事件。
6. 停止并重启本地 Relay（同一 SQLite 文件），浏览器和 mock 自动重连，房间/邀请码/日志仍在。断开时开始/停止禁用。

首次尝试 headless Chrome 受沙箱限制退出，之后改用已连接 Chrome 完成上述实测；没有把失败的 headless 脚本算作通过。截图仅为本地临时证据：`/tmp/zsir-browser-test/control.png`，不纳入仓库。

其他检查：

- `docker compose -f server/docker-compose.yml config` 成功，构建上下文/8080 映射/SQLite 命名卷解析正确。
- `npm audit --omit=dev`（server）与 `npm audit`（control）：均 `found 0 vulnerabilities`。
- `git diff --check` 无输出。

## Claude 部署与验收

```sh
# 在仓库根目录，Debian 13 + Docker 26
# 本机联网命令须用指定 HTTPS_PROXY；服务器由 Claude 按服务器既有环境执行。
docker compose -f server/docker-compose.yml up --build -d
# http://<服务器IP>:8080/healthz 与控制端根页面
# 重启保留卷：
docker compose -f server/docker-compose.yml restart
```

本机 Docker CLI 可用，但 daemon 未运行：`/var/run/docker.sock: no such file or directory`，**没有实际构建/启动容器**。Debian 13 / Docker 26 镜像构建、卷权限和容器重启仍需 Claude 验证；本地 Node 20 的构建、SQLite 重启、静态托管、真实 ws 和浏览器联调已通过，不能替代服务器验收。

## 没做什么 / 已知边界

- 未修改 client-*，未提交、push、开 PR 或部署；未触碰 main。CI、真实 macOS/Windows 客户端、两台独立电脑及服务器容器验收未执行。
- 未做静帧/宫格图/对象存储/上传/结束任务/登录。`/download` 和安装包发布属于后续交付，当前复制文案包含该固定地址，但尚不可下载安装客户端。
- 同 IP 锁定保存在单进程内存，Relay 重启会清零；房间与待发 stop 持久化。服务端直接暴露 HTTP 端口，不信任 X-Forwarded-For；以后加反代需要显式配置可信代理。
- 当前内部信任使用，无登录，昵称不是认证身份。不要把 ack 视为已完成停录；以 recording_stopped/最新状态为准。离线 stop 可重复补发，客户端必须按指令 ID 幂等。
- SQLite 卷不要用 `docker compose down -v` 删除。
