# protocol/

客户端 ↔ Relay ↔ 控制端 共用的消息定义。权威说明见 [docs/03-protocol.md](../docs/03-protocol.md)。

- `schema/envelope.json` — 所有 WebSocket 消息的信封
- `schema/state.json` — 客户端 `state.payload`
- `schema/commands.json` — 控制端指令 `payload`（`start` / `stop` / `snapshot` / `set_quality` / `make_contact_sheet` / `upload_control` / `finish_task`）
- `schema/event.json` — `event.payload` 与事件码枚举

三端生成类型：server/control 用 `json-schema-to-typescript`；Swift / C# 手写 Codable / record 并在 CI 用示例消息做往返校验。
