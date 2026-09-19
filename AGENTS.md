# DSH 远程监控

工程根目录：`E:\Code\deepseekharness\dsh-remote`

鸿蒙 App 远程查看/操控本机 DSH 会话的完整链路：

```
鸿蒙 App ──wss──▶ 中转服务器 (relay) ◀──wss── DSH 监控插件 (plugin)
```

| 目录 | 说明 | 地址 |
|---|---|---|
| `app/` | 鸿蒙 App（包名 `com.dsh.remote.monitor`） | `E:\Code\deepseekharness\dsh-remote\app` |
| `plugin/` | DSH Cordis 插件（`dsh-remote-monitor`） | `E:\Code\deepseekharness\dsh-remote\plugin` |
| `relay/` | Node + ws 中转服务器 | `E:\Code\deepseekharness\dsh-remote\relay` |
| `deploy/` | 部署脚本 | `E:\Code\deepseekharness\dsh-remote\deploy` |
| `docs/` | 协议与方案文档 | `E:\Code\deepseekharness\dsh-remote\docs` |

- GitHub：`git@github.com:3319952332/remote-monitor-.git`

---

## 关键配置（已实测）

| 项 | 值 |
|---|---|
| bundleName | `com.dsh.remote.monitor` |
| SDK | `6.1.1(24)`，ArkTS |
| developer (团队) | `30086000718441357` |
| app-identifier | `6918739819372080951`（Profile 内字段，≠ AGC 控制台显示的 appid） |
| relay 生产地址 | `wss://console.sub.opengm.top`（TLS: Let's Encrypt，`CN=opengm.top`） |
| App 配置来源 | `relay-config.local.json`（gitignored）→ `gen-relay-config.mjs` 生成 `entry/src/main/ets/services/RelayConfig.ets`（gitignored） |
| 权限 | `INTERNET`、`KEEP_BACKGROUND_RUNNING`（均 normal 级，**无需 ACL**） |

### 明文流量说明

relay 生产用 `wss://`（TLS），走系统证书库，**无需放行明文流量**。仅在局域网用 `ws://` 调试时才需要处理明文限制。

---

## 构建与部署（已实测通过）

```powershell
$env:DEVECO_SDK_HOME = "D:\Huawei\DevEco Studio\sdk"
cd E:\Code\deepseekharness\dsh-remote\app

# 换过 bundleName 或 AGC 应用记录后必须重新生成签名材料
devecocli auth login                       # 需要华为账号 OAuth
devecocli signature generate --force

# 构建（注意 build 是复数 --modules）
devecocli build --modules entry --build-mode debug

# 部署到手机（run 是单数 --module）
devecocli run --module entry --build-mode debug --device <手机IP:端口>
```

实测结果：`BUILD SUCCESSFUL` → `App installed successfully` → `start ability successfully` → `Smoke: PASS`。

### 手机锁屏会阻止启动

`devecocli run` 在锁屏时报 `10106102`（`The device screen is locked`）。开发者模式**禁止 ADB 自动解锁**，必须手动解锁屏幕后重试。

### 连接状态怎么看

`devecocli ui layout` 可直接读设备屏幕，比翻日志高效得多：

```powershell
devecocli ui layout              # 读 UI 节点树
devecocli ui screenshot          # 截图
```

主页显示 `节点在线 (<id>)` 即表示 relay 握手成功、链路打通。

---

## 已知问题与注意事项

### 可观测性缺陷（待修）

`services/RelayClient.ets` **没有任何日志输出**：

```ts
ws.on('error', (_err: BusinessError) => {
  this.teardown('连接错误');        // 丢弃 _err，不打印
});
```

`teardown()` 只更新状态、不打日志，所以**连接失败时设备日志里查不到原因**。排查连接问题建议先补日志，或用 `devecocli ui layout` 看界面状态。

设备日志里的 `E NETSTACK: wsi is nullptr, can not trigger` 是 WebSocket 初始化期的**瞬时噪音，非故障**——实测 App 能正常连上。

### 离线推送（Push Kit）—— 已打通

完整记录见 [`docs/push-kit-plan.md`](docs/push-kit-plan.md)。结论摘要：

- **场景**：不常驻后台，App 退出后靠华为 Push Kit 送达「会话完成」通知。已实测：杀掉 App 后触发 `turn.end`，真机收到推送。
- **客户端**：`PushTokenService`（取 token）+ `DeviceIdService`（取 ODID 作稳定设备标识）。hello 帧带 `deviceId` + `pushToken`。
- **relay**：`relay/src/push.js`（签 JWT 调 v3 REST）+ `index.js` 的登记表。按 `deviceId` 存 token，断连不移除；`turn.end` 时**逐设备**判断是否需要推（前台跳过、后台/已退出则推）。
- **服务端配置**（`/etc/dsh-relay.env`）：`DSH_RELAY_SERVICE_ACCOUNT`、`DSH_RELAY_PUSH_PROJECT_ID`、`DSH_RELAY_PUSH_CATEGORY`。

三个必知的坑：

1. **服务帐号必须是项目级**。判定方法是密钥 JSON 里的 `project_id` 字段有没有值 —— 开发者级为空，会导致 `80200001 Authentication Error`。
2. **JWT 用 RS256**，官方文档写的 PS256 会被 OAuth 端点拒绝（`jwt verify error`）。
3. **请求体外层是 `payload`+`target`**，且 `clickAction` 必填，缺了报 `80100003`。

> 通知「响不响」取决于消息分类：默认（营销类）静默，需申请自分类权益才能用 `WORK`（有声+横幅）。当前发的是 `MARKETING`，能到但静默。

`relay/src/notifiers.js` 的 webhook 通道仍然保留可用（配 `DSH_RELAY_NOTIFIERS`），但已不作为主方案。

### 后台保活：已关闭

**不再使用长时任务常驻后台。** Push Kit 打通后，App 进后台就让系统正常挂起、socket 断开，离线送达交给推送。

- 开关：`app/entry/src/main/ets/services/MonitorState.ets` 的 `KEEP_ALIVE_IN_BACKGROUND`（当前 `false`）。`BackgroundTaskService.ets` 保留未删，置 `true` 即可恢复。
- 同时从 `module.json5` 移除了 `backgroundModes: ["dataTransfer"]` 与 `ohos.permission.KEEP_BACKGROUND_RUNNING`，以及三份 `keep_background_reason` 字符串 —— **恢复保活时这两处也要一起加回**（开关单独打开不生效）。
- 实测行为：进后台后 socket 数秒内断开（`client offline`），进程仍在；此后 `turn.end` 走推送送达。
- 注意 `NotificationService.ensureEnabled()` 是**通知权限**，与后台保活无关，不能一起关。

### 其他

- `app/oh-package.json5` 的 description 曾残留文件管家工程文本，已于 2026-09-19 修正
- plugin 依赖 DSH `0.1.0-rc.x` 内部 API（如 `sessionPersistence`），DSH 升级可能破坏兼容性
