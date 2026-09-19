# 同步发起方改为 App 拉取（App-pull）可行性评估

> 背景：DSH 远程监控当前是「等 DSH/插件推送 + App 少量拉取」的混合同步。三个问题（上下文占用偶发为 0、App 切模型不生效、会话标题同步慢）都源于这套同步模型。用户提议改为「App 主动发起同步」：会话由 App 限量请求 + 下拉扩展、去掉"全部"tag 精确到设备；模型切换确认后 App 主动同步；上下文进入会话时请求、收到完成/问题通知等节点再次请求。
>
> 本文件给出可行性结论、每个问题的根因（含 DSH 源码证据）与落地改动清单。日期：2026 评测。基线：`dsh-remote`（plugin/relay/App 三件套）+ DSH `0.1.1-rc.1`。

---

## 总体结论

**可行，且比现在的"等推送"更契合现有架构，应做。** 理由：

- 现有 relay 协议本来就是 request/response（App → relay → node），"App 发起请求"零新增传输层。
- relay 已经支持按 `nodeId` 钉住某个节点转发（`session.list` 带 `nodeId` 时走 `forwardToNode`，不再聚合），"精确到设备"基本不用改 relay。
- 三个问题的真正根因里，**模型切换是插件里一个确凿的正确性 bug（叠加了第二套模型选择监听被 api-proxy 覆盖）**；上下文 0% 是取值策略问题；标题慢是 N+1 请求瀑布。App-pull 重构能一并修掉。

唯一要同步发布的是 **plugin + App**（协议 v1 不变，都是加字段/加参数），relay 基本无改动。

---

## 一、现状同步模型

```
DSH 进程内插件(node) ──wss──▶ relay ──wss──▶ HarmonyOS App(client)
```

- **推送（node→App）**：`turn.end`、`session.event`（白名单）、`question/requested|resolved`、`approval/*`、`session.autocompact`、`node.online|offline`。
- **拉取（App→node）**：`session.list` / `session.title` / `session.history` / `session.usage` / `session.selectModel` / `model.list` 等。

问题点（详见下）：上下文与标题依赖"推送后再拉取"，推送时机/数值语义不匹配；模型切换的拉取写错了 DSH 的模型选择注册路径。

---

## 二、三个问题的根因（含证据）

### 问题 1：上下文占用偶发显示为 0

**现象**：进入会话后占用条偶发显示 `0%`，且不刷新。

**根因 A（数值语义）**：插件的 `measureUsage`（`plugin/lib/index.js` `measureUsage`/`usagePercent`）镜像 DSH web 的 `contextPressure` 投影，其 `projectedTokens = max(0, pressureTokens + surfaceTokens − sampledSurfaceTokens)`（`dsh-token-meter` 的 `contextPressureProjectionDefinition.view`）。**压缩（含自动压缩）后 surface 被裁剪到采样点以下，`projectedTokens` 会被钳到 0**。App 侧 `usedTokens()` 优先取 `projectedTokens`（`SessionDetail.ets` `usedTokens`），于是 0 直接显示成 `0%`，而实际 surface 并非 0。

**根因 B（刷新时机）**：`SessionDetail` 只在 `aboutToAppear` / `turn.end` / 运行中 `session.event` / 2.5s 轮询里 `loadUsage()`。冷会话 `session.usage` 返回 `usage: null`（无条），用户发送后、`turn.end` 前这段窗口无占用条；`question/requested` 时也不拉。→ 与用户判断一致：**缺"进入即拉、关键节点再拉"的同步点**。

### 问题 2：App 切模型确认后，发送消息仍用旧模型

**现象**：App 里切模型 → toast"已切换至 X" → 下一条消息实际仍走默认/旧模型。

**根因（已用 DSH 源码坐实）**：DSH web 的 api-proxy 在**每次创建/恢复 agent 的 setup 里**调用 `installSelection(agentCtx)`（`dsh-host-apiproxy/lib/index.js` `composeAgent` L1754-1768），它把 `installModelSelection(agent.ctx, selection)` 装进 agent 上下文，`selection` 是 api-proxy 内部管理、带 `get/set current` 的**同一个对象**（`selectionFor` L1692-1715）。

而插件的 `session.selectModel`（`plugin/lib/index.js` `selectSessionModel`）做的是**再装一套** `installModelSelection(agent.ctx, { current: {provider,model}, assembled: undefined })`——一套**独立的、新的**监听器。

Cordis waterfall 的语义（`cordis/lib/index.js` `waterfall` L317-325）：**先注册的监听器在最外层，它在 `await next()` 之后才应用自己的覆盖 → 后注册的（内层）先改、先注册的（外层）最后改 → 最终结果 = 最早注册的那套**。于是：

- 若 web GUI 先碰过该会话（api-proxy 的监听先装）→ `agent/request` 上 api-proxy 的 `selection.assembled`（默认/日志模型）把插件选的模型**覆盖掉** → 切换不生效；
- 即使 web GUI 没碰过，插件每次 `session.selectModel` 都 `installModelSelection` 一次，**多套监听叠加泄漏**，且最旧的一套装得最早、外层最后改 → **连续切换多次时只有第一次生效**。

两者共同造成"有概率不生效 / 换不过去"。注意 DSH 的 `selectModel` 还会 `defaults.saveDefaultModelSelection`，插件路径没做，默认模型也不变。

### 问题 3：会话标题同步慢

**现象**：会话列表标题半天不出来 / 更新不及时。

**根因**：
- 插件 `listSessions`（`plugin/lib/index.js`）**故意**不返回标题（`title: null`），App 首页 `MonitorHome` 靠 `session.title` 以 3 并发慢慢拉（`scheduleTitleLoad`/`pumpTitleQueue`）——典型的 **N+1 请求瀑布**；每次 `loadSessions()` 又把标题全部清空重拉，会话一多就很慢。
- DSH 标题是**首轮回复后异步（LLM）生成**并写 `session/title` 事件。App 只在 `turn.end` 时 `loadSessions()` 重拉，此时标题往往还没写好 → 拉到 null，之后又不重拉（除非再次 turn.end 或手点刷新）。
- 插件没有把 `session/title` 事件推给 App（`FORWARD_EVENT_TYPES` 不含它），App 无法感知"标题已生成"。

---

## 三、建议方案（App-pull 重构）

### 3.1 会话列表：限量分页 + 内联标题 + 按设备

**插件 `plugin/lib/index.js`**
- `listSessions(p)` 增加分页参数 `limit`（默认 20）/ `offset`，返回 `{ rows, hasMore }`。
- 标题改为**内联**：用 DSH 的批量标题 API `sessionQuery.readTitleSnapshots(ids)`（`dsh-session-query`，一次调用取 N 个标题，替代 N 次 `session.title`）。
- 排序：running → live → `updatedAt` 倒序（保持现状），分页就是在这个有序快照上切。
- 保留 `cwd` 过滤（WorkspaceBrowser 继续用）；保留 `live`/`running`/`updatedAt`。

**relay `relay/src/protocol.js`**
- 基本不动。`session.list` 带 `nodeId` 时已走单节点转发（`AGGREGATE_METHODS && !frame.nodeId` 才聚合）。若 App 完全不再用"全部"，可把 `session.list` 从 `AGGREGATE_METHODS` 挪到普通方法，防止误用聚合。

**App `MonitorHome.ets`**
- **去掉"全部"tab**，默认选中"最后使用的设备"（`preferences` 持久化），无记录则选第一个在线节点；设备离线时列表显示上次缓存 + 离线提示。
- 会话列表改为**分页 + 下拉加载更多**（`List` 的 `onReachEnd` 或 `Refresh`），pageSize=20；`hasMore=false` 停止加载。
- 标题直接来自 `session.list` 返回，**删除 `scheduleTitleLoad`/`pumpTitleQueue`/`fetchTitle`/`titleQueue` 整条 N+1 逻辑**。
- 工作区列表：维持"全部"或同样按设备（见下方确认项）。

### 3.2 模型切换：App 确认后走 DSH 原生路径同步

**插件 `plugin/lib/index.js`**
- **`selectSessionModel`**（核心修复①）：不再 `installModelSelection` 叠加监听。改为直接调用 api-proxy 的原生 handler（与 web GUI 同路径，改的是**同一个** selection 对象，并保存默认模型）：
  ```js
  const resp = await scope.apiProxy.sessions.selectModel({
    rpcId: randomUUID(),
    payload: { sessionId, provider, model, ...(reasoningEffort ? { reasoningEffort } : {}) },
  });
  // resp.result.ok → { selected }, 否则抛出 resp.result.error.message
  ```
- **`ensureAgent` / `createSession`**（核心修复②）：api-proxy 在场时，**恢复/创建会话不再装模型选择监听**，而是把"会话日志模型 ?? 默认模型"作为 `agentOptions` 种进 AgentOptions（保证冷会话首轮用对模型）。原因：Cordis waterfall 里先注册的监听最外层、最后覆盖，插件自装监听会永久压过 api-proxy 的 `selectionFor`（以及 web GUI 的切换）。现在 api-proxy 的 `selectionFor` 是**唯一**模型选择来源（首次触碰时自装）。
- 非 web profile（无 api-proxy）保留原 `installModelSelection` 兜底。

**App `SessionDetail.ets` `switchModel`**
- 成功后用返回的 `selected` 更新 `currentProvider/currentModel`；并把 `model.list` 里当前会话 `models` 端点的 `current` 读回来做**校验展示**（可选增强）。
- 切换成功后顺带 `loadUsage()`（上下文条跟随模型变化刷新）。

### 3.3 上下文：进入/完成/问题节点拉取 + 数值健壮性

**App `SessionDetail.ets`**
- `aboutToAppear` 已拉（保留）；`handleEvent` 里 **`question/requested` 时也 `loadUsage()`**；`session.autocompact` 已拉（保留）。
- `usedTokens()` 取值规则改为「投影为正用投影，投影为 0 但 surface 为正用 surface」：
  ```ts
  if (typeof u.projectedTokens === 'number' && u.projectedTokens > 0) return u.projectedTokens;
  if (typeof u.surfaceTokens === 'number' && u.surfaceTokens > 0) return u.surfaceTokens;
  if (typeof u.pressureTokens === 'number' && u.pressureTokens > 0) return u.pressureTokens;
  return null; // 真·空会话/未知 → 隐藏条，而不是显示 0%
  ```
- 冷会话进入后若 `session.usage` 为 null，可先按"无数据"隐藏条；发送后靠 turn.end 刷新（现状已具备）。

**插件 `plugin/lib/index.js` `measureUsage`**
- 投影分支里当 `projectedTokens === 0 && surfaceTokens > 0` 时，把 `projectedTokens` 置为 null（交给 App 走 surface），避免把"刚压缩完"误导成"0%"。也可在返回里加 `compacted: boolean` 供 UI 提示。

---

## 四、改动清单（逐文件）

| 文件 | 改动 |
|---|---|
| `plugin/lib/index.js` | `listSessions` 分页+`hasMore`+内联标题（`readTitleSnapshots`）；`selectSessionModel` 走 `apiProxy.sessions.selectModel`（保留非 web 兜底）；`measureUsage` 投影为 0 但 surface>0 时置 null |
| `relay/src/protocol.js` | 可选：`session.list` 移出 `AGGREGATE_METHODS`（App 不再用"全部"） |
| `app/.../model/Protocol.ets` | `SessionListParams` 加 `limit/offset`；`SessionListResult` 加 `rows/hasMore`（或平铺 `items/hasMore`） |
| `app/.../pages/MonitorHome.ets` | 去掉"全部"tab、默认设备持久化、分页+下拉加载更多、删除标题 N+1 队列 |
| `app/.../pages/SessionDetail.ets` | `usedTokens` 取值健壮化；`question/requested` 时 `loadUsage`；切模型成功用返回 `selected` |
| `app/.../services/RelayClient.ets` | 无改动（协议 v1，request 本就支持任意 params） |
| 部署 | App 与 plugin 需同版部署（App 期望新 `session.list` 返回结构）；协议版本号不变 |

## 五、风险与注意

1. **offset 分页在"活动列表"上有漂移**（会话新增/完成导致顺序变化，翻页可能漏/重）。监控列表可接受；若要严格，改用 `updatedAt` 游标。建议先 offset 简单实现。
2. **去掉"全部"tab**：设备全离线时 App 要能降级（缓存上次数据 + 明确离线态），否则空屏难排查。
3. **api-proxy 路径依赖**：`apiProxy.sessions.selectModel` 仅在 web profile（`dsh web`）可用；headless 场景保留 `installModelSelection` 兜底。两分支都要冒烟。
4. **内联标题成本**：`readTitleSnapshots` 是 SQLite 批量读，20 条一次 O(1) 请求，可控；冷会话标题回退逻辑（首条 user 消息）可保留。
5. **上下文数值**：压缩后 web 桌面同样短暂显示低占用，App 走 surface 后行为与桌面"有内容≠0"一致，属于体验优化而非破坏一致性。
6. **兼容**：老 App + 新 plugin（或反之）期间，`session.list` 结构变了会不兼容——开发期用同一调试 relay 同步换。

## 六、关于调试连接地址 192.168.31.214:35559

- 该地址 TCP 可达；用生产 token 探测握手被拒（`socket hang up`），说明调试 relay 用不同 token（预期，本地调试实例）。
- 当前 `app/relay-config.local.json` 指向 `wss://console.sub.opengm.top`（生产）。调试前需改为 `ws://192.168.31.214:35559` + 调试 token，再跑 `node gen-relay-config.mjs` 重生成 `RelayConfig.ets`。
