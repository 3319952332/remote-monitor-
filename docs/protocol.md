# DSH 远程监控协议 v1

三件套（DSH 监控插件 / 中转服务器 / 鸿蒙 App）的共同契约。

## 拓扑

```
鸿蒙 App (client) ──wss──▶ 中转服务器 (relay) ◀──wss── DSH 监控插件 (node)
```

- **node**：DSH 进程内的 Cordis 插件，主动出站连 relay，是唯一能碰 DSH 数据的角色。
- **client**：鸿蒙 App，主动出站连 relay，发请求、收事件。
- **relay**：纯消息枢纽，鉴权 + 请求路由 + 事件广播，不碰 DSH 数据本身。

## 传输

WebSocket，文本帧，负载为 UTF-8 JSON。协议版本号 `v: 1`。

## 通用帧

```jsonc
{
  "v": 1,            // 协议版本
  "type": "request", // 帧类型，见下
  "id": "uuid",      // 帧 id；request/response 用它配对
  // ... 类型特定字段
}
```

## 握手

连接建立后第一条消息必须是 `hello`，服务端回 `welcome` 或 `error`。

```jsonc
// node → relay
{ "v":1, "type":"hello", "role":"node", "token":"<secret>",
  "name":"my-dsh", "hostname":"PC", "platform":"win32", "pid":1234, "version":"0.1.0" }

// client → relay
{ "v":1, "type":"hello", "role":"client", "token":"<secret>",
  "deviceName":"Mate60", "platform":"harmonyos" }

// relay → node/client
{ "v":1, "type":"welcome", "id":"<连接id>", "role":"node" }
{ "v":1, "type":"error", "code":"AUTH_FAILED", "message":"..." }
```

## 请求-响应

client 发 `request`，relay 路由到 node（默认第一个在线 node，可指定 `nodeId`），node 回 `response`，relay 转发给原 client。

```jsonc
// client → relay
{ "v":1, "type":"request", "id":"r1", "nodeId": null, "method":"session.list", "params": {} }

// node → relay
{ "v":1, "type":"response", "id":"r1", "ok":true, "result": { ... } }
{ "v":1, "type":"response", "id":"r1", "ok":false, "error": { "code":"...", "message":"..." } }
```

### 方法表

| method | params | result |
|---|---|---|
| `node.list` | — | `[{ id, name, hostname, connectedAt }]`（relay 本地处理） |
| `workspace.list` | — | `[{ id, path, title, sessionIds, createdAt, updatedAt }]` |
| `session.list` | `{ workspaceId? }` | `[{ id, createdAt, cwd, live }]` |
| `session.history` | `{ sessionId, fromSeq? }` | `{ meta, events: SessionEvent[] }` |
| `session.create` | `{ cwd?, provider?, model? }` | `{ sessionId, cwd }` |
| `session.prompt` | `{ sessionId, text }` | `{ ok, sessionId }` |
| `agent.list` | — | `[{ id, status, sessionId }]` |
| `fs.listDir` | `{ path }` | `{ entries: [{ name, type, size? }] }` |
| `fs.readText` | `{ path, maxBytes? }` | `{ content }` |

## 事件（node → relay → 所有 client）

```jsonc
{ "v":1, "type":"event", "id":"e1", "event":"turn.end",
  "sessionId":"session-...", "data": { "turn":3, "reason":{ "kind":"completed" } } }
```

| event | data | 说明 |
|---|---|---|
| `node.online` / `node.offline` | `{ id, name }` | relay 本地产生 |
| `session.created` | `{ sessionId, header }` | 新会话 |
| `session.disposed` | `{ sessionId }` | 会话销毁 |
| `turn.end` | `{ turn, reason }` | **回合完成（弹窗触发）** |
| `session.event` | `{ event: SessionEvent }` | 原始事件透传（白名单：user/message、assistant/message、tool/call、tool/result、turn/start、todo/write） |

## 心跳

```jsonc
{ "v":1, "type":"ping", "t": 1234567890 }
{ "v":1, "type":"pong", "t": 1234567890 }
```

任一方 60s 内未收到对端消息即判定断线，主动 close。node 断线后带指数退避重连。

## 鉴权

单一共享 token（relay 配置 `token`），node 和 client 握手时携带，不匹配即 `AUTH_FAILED` 断开。个人项目足够；如需多用户再扩展为 token 表。

## 错误码

`AUTH_FAILED`、`NO_NODE`（无在线 node）、`NODE_TIMEOUT`（node 无响应）、`BAD_REQUEST`、`NOT_FOUND`、`INTERNAL`。
