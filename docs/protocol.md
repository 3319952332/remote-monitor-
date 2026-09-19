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
// deviceId 是稳定设备标识（App 取 ODID），relay 用它当推送登记表的键；
// deviceName 只是展示名，每个安装都一样，不能拿来当键。
// pushToken 是 Push Kit token，由 relay 在无前台客户端时用来推送。
{ "v":1, "type":"hello", "role":"client", "token":"<secret>",
  "deviceName":"Mate60", "deviceId":"odid-dff3cdfd-...", "platform":"harmonyos",
  "pushToken":"<Push Kit token>" }

// relay → node/client
{ "v":1, "type":"welcome", "id":"<连接id>", "role":"node" }
{ "v":1, "type":"error", "code":"AUTH_FAILED", "message":"..." }
```

## 应用前后台状态（client → relay）

App 在 `onForeground` / `onBackground` 时上报，让 relay 判断 `turn.end` 要不要推：

```jsonc
{ "v":1, "type":"app.state", "foreground": false, "pushToken":"<Push Kit token>" }
```

`turn.end` 的推送条件（`relay/src/index.js` 的 `shouldPush()`）：

| 情况 | 行为 |
|---|---|
| 有任一前台 client | 不推（用户正看着屏幕） |
| 有连接但全部后台 | 推（`DSH_RELAY_PUSH_WHEN_BACKGROUND`） |
| 无任何连接 = App 已退出 | 推（`DSH_RELAY_PUSH_WHEN_CLOSED`） |

> 推送登记表按 `deviceId` 存 token，**断连不移除**——App 退出正是推送要覆盖的场景。条目在 `DSH_RELAY_PUSH_TOKEN_TTL_MS`（默认 90 天）无刷新后清理，云端报 `80300007`（token 失效）时立即删除。

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
| `workspace.list` | — | `[{ id, path, title, sessionIds, createdAt, updatedAt }]`（relay 聚合所有 node，带 node 标签） |
| `session.list` | `{ cwd?, limit?, offset? }` | `{ rows: SessionInfo[], hasMore }`。**精确到单个 node**（带 `nodeId` 钉住时只查该节点；不再聚合）。`rows` 内联标题（`title`），每项带 `nodeId/nodeName/hostname` 标签 |
| `session.title` | `{ sessionId }` | `{ sessionId, title }`（保留的懒加载通道；新 App 已用 `session.list` 内联标题，不再依赖） |
| `session.history` | `{ sessionId, fromSeq? }` | `{ meta, events: SessionEvent[] }` |
| `session.create` | `{ cwd?, provider?, model? }` | `{ sessionId, cwd }` |
| `session.prompt` | `{ sessionId, text }` | `{ ok, sessionId }` |
| `session.selectModel` | `{ sessionId, provider, model }` | `{ selected: { provider, model } }` |
| `session.permission` | `{ sessionId, preset }` | `{ sessionId, switched, preset }` |
| `question.answer` | `{ sessionId, questionRpcId, answers }` | `{ answered, sessionId, questionRpcId }` |
| `agent.list` | — | `[{ id, status, sessionId }]`（relay 聚合所有 node，带 node 标签） |
| `fs.listDir` | `{ path }` | `{ entries: [{ name, type, size? }] }` |
| `fs.readText` | `{ path, maxBytes? }` | `{ content }` |

> **session.list 分页**（App 拉取模型）：默认 `limit: 20`、`offset: 0`，服务端在固定排序快照（running → live → updatedAt 倒序）上切片，返回 `{ rows, hasMore }`。App 首页每设备一页页拉取（下拉刷新回第 0 页、滚动到底/加载更多按钮取下一页）。标题由插件用 `readTitleSnapshots` 批量内联，不再 N+1 请求。

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
| `question/requested` | `{ questions: AskUserQuestionItem[] }` | **AI 发起了问题（需要 App 答复）** |
| `question/resolved` | `{ questionRpcId, outcome }` | 问题已解决（answered / cancelled） |
| `approval/requested` | `{ approvalId, toolName, callId?, reason? }` | **AI 需要权限审批** |
| `approval/resolved` | `{ approvalId, outcome }` | 审批已解决 |

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
