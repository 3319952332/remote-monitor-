# 鸿蒙监控 App（无 AGC）

远程查看/操控本机 DSH 会话的 ArkTS 客户端，通过 `@ohos.net.webSocket` 连中转服务器。

## 已提供的源码

```
entry/src/main/ets/
├── model/Protocol.ets                 # 协议帧 + 领域数据模型
├── services/RelayClient.ets           # WebSocket 客户端（握手/请求/事件/心跳/重连）
├── services/RelayInstance.ets         # 全局单例 + 连接配置（改这里）
├── services/NotificationService.ets   # 本地通知（会话完成，无需 AGC）
└── pages/
    ├── MonitorHome.ets                # 主页：连接状态 + 工作区 + 会话列表 + 完成弹窗
    ├── SessionDetail.ets              # 会话详情：转录 + 发消息
    ├── NewSession.ets                 # 新会话：选目录 + 首条消息
    └── WorkspaceBrowser.ets           # 工作区文件浏览 + 读文件
```

## 组装到 DevEco 工程

推荐**复用现有 `E:\Code\Huawei\AITest` 工程骨架**（签名/构建已配好），或新建 Empty Ability 工程后替换。

### 1. 拷源码

把上面 `ets` 目录整体覆盖到工程的 `entry/src/main/ets/`（保留工程自带的 `entryability/`）。

### 2. 改 `entry/src/main/module.json5`

`requestPermissions` 已需包含（AITest 已有）：

```json5
"requestPermissions": [ { "name": "ohos.permission.INTERNET" } ]
```

**明文 ws:// 放行**：HarmonyOS NEXT 默认禁明文流量（`ERR_CLEARTEXT_NOT_PERMITTED`）。
局域网用 `ws://` 时需放行明文；具体配置字段随 SDK 版本变化，请在 DevEco 里按当前
SDK 文档配置（历史 FA 模型是 `deviceConfig.network.cleartextTraffic: true`；Stage 模型
的等效项以 SDK 6.1 文档为准）。**替代方案**：公网用 `wss://` + 正式证书（Let's Encrypt），
系统证书库天然信任，无需放行明文。

### 3. 改 `entry/src/main/resources/base/profile/main_pages.json`

```json
{ "src": [ "pages/MonitorHome" ] }
```

（其余页面用 `router.pushUrl` 动态跳转，不必在此注册，但加上更稳妥：
`pages/SessionDetail`、`pages/NewSession`、`pages/WorkspaceBrowser`。）

### 4. 改 `services/RelayInstance.ets` 连接配置

```ts
export const RELAY_URL = 'ws://192.168.1.100:8787';  // 改成 relay 实际地址
export const RELAY_TOKEN = 'your-secret-token';        // 与 relay 一致
```

### 5. 编译运行

DevEco Studio 打开工程 → 签名（AITest 已有 debug 签名）→ 真机运行。

## 功能对照

| 需求 | 实现 |
|---|---|
| 查看工作区 | MonitorHome 工作区列表 + WorkspaceBrowser 文件浏览/读文件 |
| 新会话 | NewSession（选目录 + 首条消息 → session.create/prompt） |
| 老会话 | MonitorHome 会话列表（历史 + 运行中）→ SessionDetail 转录 |
| 完成弹窗 | `turn.end` 事件 → 前台 `promptAction.showDialog` + 通知栏 `publish` |

## 已知边界

- ArkTS 代码未在 DevEco 编译验证（本环境无 DevEco），字段名如与 SDK 有出入按 IDE 提示微调。
- 通知栏提醒仅在前台/退后台短时宽限内可靠；长时间离机的提醒走 relay 的 webhook 通道（ServerChan/企业微信/邮件）。
- 明文 ws 放行的具体配置字段需按你的 SDK 版本现场确认。
