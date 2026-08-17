# 部署备忘（给未来的自己 / AI 看）

> 这是 dsh-remote（DSH 远程监控：插件 + relay + 鸿蒙 App）的构建/发版全流程备忘。
> **构建 App 前务必先读「1. 构建 App」**，否则会漏掉配置生成步骤。

---

## 0. 两套"不提交"的本地配置（关键）

真实凭据/路径都不进 git，集中在本地文件里：

| 文件 | 进 git? | 内容 |
|---|---|---|
| `app/relay-config.local.json` | ❌ gitignore | relay 真实 `relayUrl` + `token`，改配置只改这里 |
| `app/entry/src/main/ets/services/RelayConfig.ets` | ❌ gitignore | 由脚本生成，含真实值，勿手改 |
| `app/build-profile.json5` | ❌ gitignore | 签名凭据（keyPassword/storePassword）+ 绝对路径 |
| `app/build-profile.json5.example` | ✅ | 签名脱敏模板 |

---

## 1. 构建 App（鸿蒙端）

```powershell
cd E:\Code\Huawei\dsh-remote\app

# 1) 必须先跑：读 relay-config.local.json 生成 RelayConfig.ets
node gen-relay-config.mjs

# 2) 再构建 + 签名 + 安装 + 启动
$env:DEVECO_SDK_HOME = "D:\Huawei\DevEco Studio\sdk"
devecocli run --module entry --build-mode debug
```

要点：

- `RelayInstance.ets` 只 import 生成的 `RelayConfig.ets`，**不要**在里面硬编码 URL/token。
- 设备：HUAWEI Mate 60 Pro+，`hdc` 经 wifi 连（`devecocli run` 会自动选设备）。
- 签名：`devecocli signature generate --force` 需要华为账号登录（`devecocli auth login`）。
- 两个 App 共存，**别覆盖**：
  - `com.example.aitest` = 文件管家（用户原有，绝不能动）
  - `com.dsh.remote.monitor` = DSH 监控（本项目）

---

## 2. 部署插件（改 `plugin/lib/index.js` 后）

DSH 的 HMR 会忽略 `node_modules`，所以**改代码**必须 bump 版本目录：

```powershell
# 1) 复制到新版本目录（N 递增）
$dst = "$env:USERPROFILE\.dsh\profiles\node_modules\dsh-remote-monitor-vN"
Copy-Item -Recurse -Force "E:\Code\Huawei\dsh-remote\plugin" $dst

# 2) 改 ~/.dsh/profiles/web/cordis.patch.yml 里的 name
#    name: dsh-remote-monitor-vN
```

改完 patch 文件，DSH 会热加载（relay 日志出现 `node offline/online` 即成功）。
只改插件**配置**（不动 lib/index.js）则直接改 patch 配置即可，无需 bump。

---

## 3. relay（中转服务器）

**生产环境**：relay 部署在远程服务器（`console.sub.opengm.top`），nginx 前置 TLS 终止，后端 relay 监听 `127.0.0.1:8787`（ws 非 wss）。

```
客户端/插件 ──wss──→ nginx (TLS) ──ws──→ localhost:8787 relay
```

- relay 管理：`systemctl status dsh-relay`
- nginx 管理：`systemctl status nginx`，TLS 证书在 `/etc/nginx/opengm/console.sub.*`
- 本机不再跑 relay；开发阶段才在本机 `node src/index.js` 临时起

**本地 relay（仅开发/故障时）**：`node src/index.js` 监听 `0.0.0.0:8787`。

### 3.1 多节点（多 DSH 终端）

架构：App 连的是 relay，**节点对 App 透明**，区分靠 relay 下发时打 tag。

- 事件（`turn.end` / `session.event` / `node.online/offline`）都带 `nodeId` + `nodeName` + `hostname`。
- 列表方法（`session.list` / `workspace.list` / `agent.list`）不指定 nodeId 时，relay 会**广播给所有节点并聚合**，每条结果打节点 tag。
- App 主页全展示、完成通知带 `【设备名】`；点进会话/工作区会带上该条目的 `nodeId`，后续定向操作（`session.history`/`prompt`/`fs.*`）精确路由到对应节点，不会串设备。
- **多台终端要能区分**：每台机器在 `cordis.patch.yml` 里给插件配不同的 `name:`（或删掉 `name:` 让它用 hostname）。否则多台都叫 `my-dsh`，只能靠 hostname 区分。

### 3.2 节点清单

- `my-dsh`：本机（Windows），`name: my-dsh`。
- `laowang`：另一台 Linux (Ubuntu) 机器，经 SSH 访问（入口在本机 `~/.ssh/config` 里，用户 `laowang`）。插件已装 `dsh-remote-monitor-v7`，`name: laowang`。上线后 relay 里显示为 `laowang@ubuntu`。重启 DSH：`ssh ... kill <pid>; nohup node ~/.npm/_npx/1e7f6d9597241db0/node_modules/.bin/dsh --profile web --host 127.0.0.1 --port 3080 > /tmp/dsh.log 2>&1 &`

> **新增节点标准步骤**：`scp -r plugin <node>:/tmp/x` → ssh `mv /tmp/x ~/.dsh/profiles/node_modules/dsh-remote-monitor-vN` → 把 `insert` 段追加到 `<node>:~/.dsh/profiles/web/cordis.patch.yml`（`relayUrl` 统一用 `wss://console.sub.opengm.top`，`token` 同 `app/relay-config.local.json`，`name` 给唯一名）。DSH 热加载后，relay 日志出现 `node online: <name>@<hostname>` 即成功；不用 npm install（插件无第三方依赖，`@deepseek-ai/*` 由 DSH 自己的树解析）。如果热加载不生效，重启 DSH 进程。

---

## 4. 通知行为（已完成，别改回去）

App 完成通知最终配置（`NotificationService.ets`）：

- `notificationSlotType = SOCIAL_COMMUNICATION`（保证横幅）
- `notificationFlags`：`soundEnabled:1`（有声）、`vibrationEnabled:2`（无震动）、`bannerEnabled:1`（横幅）
- 点击通知打开 App：`wantAgent` 已在 `NotificationService.init()` 里缓存

注意：`NotificationFlagStatus` 枚举 SDK 未导出，数字 + 整体 `as` 断言才能过编译（ArkTS 不支持索引访问类型 `T['k']`）。

---

## 5. 已知坑 / 边界（无 AGC 天花板）

- **锁屏启动报 `10106102`**：开发者模式下系统不能自动解锁，App 已装上、只是没自动拉起，手动点开即可（非错误）。
- **实况窗/灵动岛**：第三方 App 无法直接创建（SDK 明确 `cannot directly create`），做不了。
- **锁屏深睡眠收不到完成通知**：无 AGC/Push Kit 的天花板，长时任务保活 + 应用锁是能做的最优，锁屏冻结仍可能断。
- **子会话过滤**：插件已跳过 `origin === 'subagent'` 的一切事件，只有顶层主会话触发通知。

---

## 6. git

- 仓库根：`E:\Code\Huawei\dsh-remote`，remote `git@github.com:3319952332/remote-monitor-.git`。
- 提交前跑一遍敏感信息扫描：token / `192.168.` / 密码（见 `app/build-profile.json5` 已被 gitignore）。
- 真实值只存在于 `app/relay-config.local.json` 与生成的 `RelayConfig.ets`，两者均 gitignore。
