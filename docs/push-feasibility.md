# DSH监控 推送能力方案评估

> 日期：2026-09-19
> 范围：鸿蒙 App（`com.dsh.remote.monitor`）如何把「DSH 会话完成」通知到用户，含离线场景。
> 结论先行：**短期不必接 Push Kit，用现有的 relay webhook 通道即可覆盖离线提醒；Push Kit 留作可选增强。**

---

## 一、现状（已核实的代码事实）

### 1.1 通知链路

```
DSH 会话回合结束
   └─▶ plugin（进程内订阅事件）
        └─▶ relay（wss://console.sub.opengm.top）
             ├─▶ App（WebSocket 在线时）─▶ NotificationService.publish 本地通知
             └─▶ webhook（turn.end 触发）─▶ ServerChan / 企微 / 邮件 等
```

### 1.2 能力边界

| 场景 | App 能否收到提醒 | 依据 |
|---|---|---|
| App 在前台 | ✅ 弹窗 + 通知栏 | `MonitorHome` 收 `turn.end` → `promptAction.showDialog` + `notificationManager.publish` |
| App 退后台（短时） | ✅ 通知栏 | 同上，系统短时宽限内 `publish` 仍可调用 |
| App 退后台（长时） | ⚠️ 尽力而为 | `BackgroundTaskService` 申请 `DATA_TRANSFER` 长时任务保活 WebSocket；但长时任务**非永生**，系统仍可回收 |
| App 被杀 / 手机重启后未打开 | ❌ 完全收不到 | WebSocket 已断开，无系统级推送通道 |

**关键结论**：当前通知是「**App 活着才有**」，不是真正的推送。这是刻意的设计取舍——代码注释明确写着 `no AGC/Push Kit required`。

### 1.3 已具备的能力（无需新开发）

- **本地通知**：`NotificationService.ets`，含点击通知自动跳转到对应会话（`wantAgent` 深链）
- **长时任务保活**：`BackgroundTaskService.ets`（`DATA_TRANSFER`），已配 `KEEP_BACKGROUND_RUNNING` 权限
- **webhook 离线提醒**：`relay/src/notifiers.js` **已完整实现并接线**（`relay/src/index.js:361-362`，`turn.end` 触发 `notifyTurnEnd`）
  - 失败只记日志、不抛异常，坏 webhook 不会影响实时事件链路
  - 只差**在 relay 环境变量里填入 channel**（`DSH_RELAY_NOTIFIERS`）
- **权限**：`INTERNET` + `KEEP_BACKGROUND_RUNNING`，均 normal 级，**不需要 ACL 申请**

---

## 二、候选方案

### 方案 A：维持现状 + 补齐 webhook（推荐）

保持 `wss 长连接 + 长时任务 + 本地通知`，同时在 relay 上启用 webhook channel。

| 维度 | 评估 |
|---|---|
| 开发量 | **≈0**（代码已存在，只需配 `DSH_RELAY_NOTIFIERS` 环境变量） |
| 离线可达 | ✅ 手机不用打开、App 被杀都能收到（走微信/企微/短信，与 App 无关） |
| 需 AGC 介入 | ❌ 不需要 |
| 交互性 | ⚠️ 弱于原生推送：点击 webhook 消息不能直达会话页，只能看到文字摘要 |
| 依赖 | ServerChan / 企业微信机器人 / 邮件桥（任选，都免费） |

**适用**：自用、低频提醒（"跑完了告诉我"）。这是**当前性价比最高的路径**。

### 方案 B：接入华为 Push Kit（真离线推送）

App 侧接入 Push Kit 拿 Push Token，relay 侧在手机不在线时改调华为推送 API。

| 维度 | 评估 |
|---|---|
| 开发量 | **中等偏大**：App 侧集成 + relay 侧改造 + AGC 配置 |
| 离线可达 | ✅ 系统级通道，App 被杀也能收到，且可点击直达 App |
| 需 AGC 介入 | ✅ **必须**（见下方清单） |
| 需 Server SDK | ✅ 需要（服务端调推送 API） |
| 依赖 | 华为推送服务，且**用调试证书需在 AGC 添加公钥指纹** |

**接入前置清单（缺一不可）**：

1. AGC 中 `com.dsh.remote.monitor` 记录存在（已有新 appid `6917616843236218365`）
2. AGC 为该项目**开通「推送服务」**
3. AGC **添加公钥指纹**（选调试证书 `default_app_*.cer`）——调试阶段即可测试，不要求已上架
4. `module.json5` 增加 `metadata`：`{ "name": "client_id", "value": "<AGC 的 Client ID>" }`
5. App 侧 `@kit.PushKit` 的 `pushService.getToken()` 获取 Push Token 并上报 relay
6. relay 侧增加推送发送逻辑（调华为 Push API / Server SDK），并维护 `device ↔ pushToken` 映射
7. 考虑 AGC「自分类权益」申请（消息分类，否则推送可能受限）

> 参考：[个推 HarmonyOS 厂商应用开通指南](https://docs.getui.com/getui/mobile/harmonyos/harmonyosstudio/) 完整描述了上述 1-3 步与指纹添加位置。

### 方案 C：混合（长连接为主 + 离线时走推送）

在线走 WebSocket（实时、可交互），SDK 判定离线时 relay 改发 Push Kit 通知。

| 维度 | 评估 |
|---|---|
| 开发量 | 最大（= 方案 B + 在线/离线状态判定与切换） |
| 体验 | 最好：在线即时、离线可达 |
| 复杂度 | 需要 relay 维护 node/client 在线状态并对齐推送去重，避免"在线也推、离线也推" |

**建议**：等方案 B 跑通、确有体验痛点后再演进到 C，不要一开始就做。

---

## 三、对比与建议

| | A 现状+webhook | B Push Kit | C 混合 |
|---|---|---|---|
| 开发量 | ≈0 | 中偏大 | 大 |
| App 被杀可达 | ✅（经微信等） | ✅（原生） | ✅ |
| 点击直达会话 | ❌ | ✅ | ✅ |
| 需 AGC | ❌ | ✅ | ✅ |
| 需 Server SDK | ❌ | ✅ | ✅ |
| 推荐度 | ⭐⭐⭐ **先做** | ⭐⭐ 可选 | ⭐ 暂不做 |

### 建议路线

1. **立即**：方案 A —— 在 relay 配 `DSH_RELAY_NOTIFIERS`（一个 JSON 数组，如 ServerChan 的 URL），离线提醒立刻可用，零代码改动。
2. **观察**：用一段时间，看 webhook 的"无交互、需切到微信看"是否真的构成痛点。
3. **按需**：若痛点成立，再按方案 B 接 Push Kit（清单见上），届时再评估是否演进到 C。

### 不建议现在做的理由

- Push Kit 需要 AGC 侧一连串配置（推送服务开通、指纹、client_id、消息分类权益），且服务端要接 SDK，**工作量数倍于收益**；
- 而 webhook 方案**代码已经写好并接线**，只差配置——先拿到 90% 收益再决定是否追最后 10%。

---

## 四、方案 A 落地步骤

在 relay 的运行环境（生产为 systemd 托管）设置：

```bash
DSH_RELAY_NOTIFIERS='[{"type":"webhook","url":"https://sctapi.ftqq.com/<你的SENDKEY>.send"}]'
```

- ServerChan 申请：<https://sct.ftqq.com>
- 也可换成企业微信机器人 webhook（`{"type":"webhook","url":"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=..."}`）
- **注意**：`config.js` 要求该值必须是合法 JSON 数组，否则服务启动即抛错
- 修改后需重启 relay 生效

验证：让任一 DSH 会话跑完一个回合，relay 日志应出现 webhook 调用；微信/企微应收到「DSH 会话完成」消息。

---

## 五、风险与备注

- **凭据管理**：webhook URL 含 key，务必走环境变量，不要写进仓库（仓库已有 `.gitignore` 机制，`relay-config.local.json` 等均已排除）
- **DSH API 兼容性**：plugin 依赖 DSH `0.1.0-rc.x` 的内部 API（`sessionPersistence` 等），DSH 升级可能破坏插件——这与推送方案无关，但会影响 `turn.end` 能否正常产生
- **长时任务的合规性**：`DATA_TRANSFER` 长时任务需有真实数据传输场景，系统会校验；当前用途（维持 WebSocket）符合
