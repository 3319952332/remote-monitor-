# Push Kit 接入方案与实测记录（DSH监控）

> 最后更新：2026-09-19
> 目标：DSH 会话回合结束时，把通知推到**手机系统通知栏**（而非微信），App 被杀也能收到，点击可直达会话页。
> 前置决策：**本方案推翻工程原有的「无 AGC」设计**（见 `README.md`、`app/README.md`、`docs/DEPLOY.md` §5）。已定：证书用**调试证书**；**不保留 webhook 降级**。

---

## 一、本工程实际参数

| 项 | 值 | 来源 |
|---|---|---|
| bundleName | `com.dsh.remote.monitor` | `AppScope/app.json5` |
| **client_id**（`module.json5` metadata） | `6917616843236218365` | AGC 推送服务页 / `oauth_client.client_id` |
| **app_id** | `6917616843236218365` | `agconnect-services.json` |
| **project_id**（REST URL） | `101653523865089045` | `agconnect-services.json`（= AGC 页面「发送者ID」） |
| cp_id（团队） | `30086000718441357` | 与签名证书一致 |
| 设备 UDID | `E1CF83CF1ED2700F50A3917D2EACA27D78DA69D07C8C7B5E771E768A8B58C5E1` | `hdc shell bm get -u` |
| relay 生产地址 | `wss://console.sub.opengm.top` | `RelayConfig.ets` |

> `agconnect-services.json` 的 `service` 段永远不含 push（它是 Android/HMS SDK 的配置文件，HarmonyOS NEXT 不读它）——**不要以它判断推送是否开通**。

---

## 二、客户端配置（四项缺一不可）

HarmonyOS NEXT 的推送配置散落在四个地方，漏任何一项都会失败：

| # | 配置 | 位置 | 缺失时的症状 |
|---|---|---|---|
| 1 | 开通推送服务 | AGC → 增长 → 推送服务 | `getToken()` 报 `1000900012` |
| 2 | **公钥指纹**（选签名证书） | AGC → 项目设置 → 常规 → 添加公钥指纹 | `getToken()` 报 `1000900010 Illegal application identity` |
| 3 | **Profile 含推送能力** | 见下方 §三 | `getToken()` 成功但**设备收不到推送** |
| 4 | **`action.ohos.push.listener`** | `module.json5` → abilities.skills.actions | 推送成功但**设备收不到** |

外加：`module.json5` 的 `metadata.client_id`（写字面量，**不能**用 `$string:` 引用）。

### 4 的正确写法

```json5
"skills": [
  {
    "entities": ["entity.system.home"],
    "actions": [
      "action.system.home",
      "action.ohos.push.listener"   // 只允许一个 ability 定义该 action
    ]
  }
]
```

> 约束：`actions` 与 `uris` **不可放在同一个 skill 对象**里，否则收不到推送。需要 uris 时另起一个对象。

---

## 三、Profile 必须包含推送能力（关键踩坑）

**签名 Profile（`.p7b`）里必须声明推送服务能力**，否则 `getToken()` 能成功、但推送投递不到设备。

对比两份 Profile 的二进制内容（实测）：

| 字段 | 无推送能力的 Profile | 有推送能力的 Profile |
|---|---|---|
| `app-services-capabilities` | **字段不存在** | `{"com.huawei.service.push.base_service":{}}` |
| `app-privilege-capabilities` | 字段不存在 | `[]` |
| 文件大小 | 4054 B | 4176 B |

**生成方式**：AGC → 证书、App ID 和 Profile → Profile → 添加 → 类型选「调试」→ 绑定调试证书 + 设备 → 提交并下载。

> ⚠️ 注意：`allowed-acls` 为空是**正常的**——推送不走 ACL，别在这里浪费时间。我们曾误判过这一点。

---

## 四、服务端鉴权（**已打通**）

### 4.1 已确证的正确做法

```
POST https://push-api.cloud.huawei.com/v3/{projectId}/messages:send
Content-Type: application/json;charset=utf-8
Authorization: Bearer <服务帐号JWT>
push-type: 0
```

- **不要**先换 access_token（HarmonyOS 5+ 不支持 OAuth2.0 开放鉴权）
- JWT 算法用 **RS256（PKCS1 v1.5）** —— 实测 OAuth 端点**拒绝 PS256**（`jwt verify error`）
- JWT header：`{ alg: "RS256", kid: <key_id>, typ: "JWT" }`
- JWT payload：`{ iss: <sub_account>, aud: "https://oauth-login.cloud.huawei.com/oauth2/v3/token", iat, exp }`

服务帐号密钥字段：`key_id`、`private_key`、`sub_account`，以及**关键的 `project_id`**（见 4.2）。

### 4.2 卡点：`80200001 Authentication Error`（已解决）

长时间误判为「服务帐号未被授权调用 Push API」，实测后**根因是凭证的层级**：

| 密钥来源 | JSON 里的 `project_id` | Push API 结果 |
|---|---|---|
| 开发者级凭证 #1 | **空** | ❌ `80200001` |
| 开发者级凭证 #2 | **空** | ❌ `80200001` |
| **项目级凭证** | **有值** | ✅ **`80000000`** |

**结论**：`project_id` 字段有没有值，就是「开发者级 / 项目级」的判据，也是 `80200001` 的根因。必须在 AGC 里创建**项目级**服务帐号凭证，不能只建开发者级的。

排查中**已排除**的假设（全部实测无效）：

| 假设 | 结果 |
|---|---|
| JWT 算法错 | RS256 可用，PS256 被 OAuth 端点拒绝 |
| `kid` 不该带 | 与成败无关 |
| 缺 `scope` | 与成败无关 |
| `aud` 取值不对 | 与成败无关 |
| 该用 access_token | HarmonyOS 5+ 不支持，v3 只用 JWT |

### 4.3 请求体结构（`80100003` 的两个坑）

外层是 **`payload` + `target`**，不是 `message`；且 **`clickAction` 必填**：

```jsonc
{
  "payload": { "notification": { "clickAction": {"actionType": 0}, "category": "MARKETING", "title": "…", "body": "…" } },
  "target": { "token": ["<Push Kit token>"] },
  "pushOptions": { "testMessage": true, "ttl": 86400 }
}
```

缺 `clickAction` → `80100003 Illegal payload, payload.notification.clickAction should not null`。

### 4.4 服务端密钥位置

```
服务器 111.229.53.125 : /etc/dsh-relay-service-account.json   (600, ubuntu:ubuntu)
```

**绝不入库**。已实现：`relay/src/push.js`（签 JWT + 调 REST）、`relay/src/index.js`（登记表 + `turn.end` 推送）。

环境变量（`/etc/dsh-relay.env`）：

```
DSH_RELAY_SERVICE_ACCOUNT=/etc/dsh-relay-service-account.json
DSH_RELAY_PUSH_PROJECT_ID=101653523865089045
DSH_RELAY_PUSH_CATEGORY=MARKETING      # 自分类权益批下来后改 WORK
```

---

## 五、客户端已完成的改动

| 文件 | 改动 |
|---|---|
| `entry/src/main/module.json5` | 加 `metadata.client_id`；`skills.actions` 加 `action.ohos.push.listener` |
| `services/PushTokenService.ets`（新建） | `getToken()` + `tokenUpdate` 监听 + 错误码中文提示 |
| `services/DeviceIdService.ets`（新建） | 取 `deviceInfo.ODID` 作稳定设备标识（免权限），取不到时用 preferences 持久化的随机 id 兜底 |
| `model/Protocol.ets` | `HelloFrame` 加可选 `pushToken` / `deviceId`；新增 `AppStateFrame` |
| `services/RelayClient.ets` | `setPushToken()` / `setDeviceId()` / `reportAppState()`；hello 携带 deviceId+pushToken；已连接时重新握手 |
| `entryability/EntryAbility.ets` | 启动取 ODID + Token 交给 relay；`onForeground`/`onBackground` 上报前后台 |

**实测**：`getToken()` 成功，Token 112 字符，重装后 Token 不变（设备+应用级稳定）。

> **为什么需要 `deviceId`**：relay 的推送登记表原本按 `deviceName` 存 token，而 App 的 `DEVICE_NAME` 是写死的常量 `'HarmonyOS'` —— 两台手机会互相覆盖，重装则留下死 token。改用 ODID 后每台设备各自一条。
>
> 踩坑：`pushService.on('tokenUpdate', ability, cb)` 的第二个参数要 **`UIAbility` 实例**（传 `this`），不是 `UIAbilityContext`。

---

## 六、relay 侧推送调度

登记表按 `deviceId` 存 token，**断连不移除**（App 退出正是推送要覆盖的场景）。`turn.end` 到达时**逐设备**判断：

| 情况 | 行为 |
|---|---|
| 该设备有前台 socket | 跳过（用户正看着） |
| 该设备有 socket 但在后台 | 推（`DSH_RELAY_PUSH_WHEN_BACKGROUND`，默认开） |
| 该设备无 socket = App 已退出 | 推（`DSH_RELAY_PUSH_WHEN_CLOSED`，默认开） |

> **踩坑**：最初写成「只要有任一前台 client 就整体不推」，多设备时后台那台永远收不到；单设备下手机亮着也会收到重复推送。必须逐设备判断。

其他：条目在 `DSH_RELAY_PUSH_TOKEN_TTL_MS`（默认 90 天）无刷新后清理；云端报 `80300007`（token 失效）时立即删除该条目。

---

## 七、验证清单

1. ✅ `getToken()` 成功拿到 Token（hilog 的 `PushToken` 标签）
2. ✅ AGC 控制台 / relay 真实推送能到手机
3. ✅ relay REST 鉴权返回 `80000000`（服务端打通）
4. ✅ **杀掉 App 后触发回合结束 → 通知栏出现推送**（`[push] sent to odid-…`）
5. ⏸ 申请自分类权益（`WORK`）→ 通知变为有声+横幅

---

## 八、其他记录

- 消息分类选「**工作事项提醒**」(`category: "WORK"`) →「用户主动设置的提醒」，别用默认的营销类（静默 + 2~5 条/日限流）。**`WORK` 需先在 AGC 申请自分类权益**；未获批前只能发 `MARKETING`（能到但静默），所以当前 relay 配置用 `MARKETING`，权益下来后改环境变量即可，代码无需动。
- 推送 Token 长度会变，**不要写死长度判断**。
- Push Token 在「卸载重装 / 恢复出厂 / 调用 deleteToken / 离开国家地区」后才变化。
- AGC 控制台测试推送需手动填 Token；「有效到达数」要等设备回执，不实时。
- 夜间（0–6 点）熄屏后系统可能管控消息下发，消息会被**缓存而非丢弃**，排查"没收到"时要考虑时段。
- **推送不只是"有没有收到"，还有"响不响"**：早期一直以为推送失败，实际是分类为营销类，消息静默进了通知中心没被注意到。
