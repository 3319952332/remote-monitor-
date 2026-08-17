# DSH 远程监控（无 AGC 方案）

鸿蒙 App 远程查看/操控本机 DSH 会话的完整链路：

```
鸿蒙 App ──wss──▶ 中转服务器 (relay) ◀──wss── DSH 监控插件 (plugin)
```

- **plugin/** — DSH Cordis 插件，进程内跑，出站连 relay，暴露会话/工作区/文件 API 并推送事件。
- **relay/** — Node + ws 中转服务器，鉴权 + 请求路由 + 事件广播 + webhook 提醒。
- **docs/protocol.md** — 三件套共同消息协议。
- **App** — 鸿蒙应用（待接入，复用 `E:\Code\Huawei\AITest` 或新建工程）。

## 1. 启动中转服务器

```powershell
cd E:\Code\Huawei\dsh-remote\relay
npm install          # 拉 ws
# 局域网明文（第一阶段，无 TLS）
$env:DSH_RELAY_TOKEN = "your-secret-token"
$env:DSH_RELAY_HOST = "0.0.0.0"
npm start            # 监听 ws://0.0.0.0:8787
```

可选环境变量：`DSH_RELAY_PORT`、`DSH_RELAY_CERT_PATH`/`DSH_RELAY_KEY_PATH`（配了即走 wss）、
`DSH_RELAY_NOTIFIERS`（JSON 数组，如 `[{"type":"webhook","url":"https://sctapi.ftqq.com/xxx.send"}]`，收到 turn.end 时 POST）。

## 2. 安装 DSH 监控插件

插件必须在 DSH 的 profile node_modules 里才能解析 `@deepseek-ai/*` 依赖：

```powershell
# 1. 复制插件到 profile node_modules（名字必须与 package.json 一致）
$dst = "$env:USERPROFILE\.dsh\profiles\node_modules\dsh-remote-monitor"
Copy-Item -Recurse -Force "E:\Code\Huawei\dsh-remote\plugin" $dst

# 2. 在 ~/.dsh/profiles/web/cordis.patch.yml 末尾追加 insert 行：
#   - insert:
#       - id: remote-monitor
#         name: dsh-remote-monitor
#         config:
#           relayUrl: ws://192.168.1.100:8787   # 改成 relay 实际地址
#           token: your-secret-token             # 与 relay 一致
#           name: my-dsh
```

`cordis.patch.yml` 是 HMR 热加载的，保存后 DSH 的 web profile 会自动重载插件，无需重启 `dsh web`。
验证：relay 日志应打印 `node online: my-dsh@...`。

> **注意（改插件代码后）**：DSH 的 HMR 会忽略 `node_modules`，所以只覆盖
> `profiles/node_modules/<pkg>/lib/index.js` 不会热更新**代码**（配置会更新、代码不会）。
> 要让运行中的 `dsh web` 加载新代码，把包复制成一个新目录名并在 `cordis.patch.yml` 里改
> `name:`（每次部署递增即可，例如 `dsh-remote-monitor-v3`）；或直接重启 `dsh web`。

## 3. 联调（无 App，用 wscat 或 node 脚本）

```powershell
# 模拟 App 客户端连 relay 后发请求
node -e "const WebSocket=require('ws');const w=new WebSocket('ws://127.0.0.1:8787');w.on('open',()=>{w.send(JSON.stringify({v:1,type:'hello',role:'client',token:'your-secret-token',deviceName:'test'}));setTimeout(()=>w.send(JSON.stringify({v:1,type:'request',id:'r1',method:'workspace.list',params:{}})),500)});w.on('message',m=>console.log(m.toString()))"
```

应返回 `workspace.list` 的结果；`turn.end` 事件会在 DSH 任一会话回合结束时推给客户端。

## 4. 鸿蒙 App

- `@ohos.net.webSocket` 连 relay；明文 `ws://` 需在 `module.json5` 放行明文流量。
- 前台收到 `turn.end` → 弹窗 + `notificationManager.publish` 本地通知（无需 AGC）。
- 长时间离机的提醒走 relay 的 webhook 通道（ServerChan/企业微信/邮件）。

## 方法/事件速查

见 `docs/protocol.md`。方法：`node.list`、`workspace.list`、`session.list`、`session.history`、
`session.create`、`session.prompt`、`agent.list`、`fs.listDir`、`fs.readText`。
事件：`node.online/offline`、`session.created/disposed`、`turn.end`、`session.event`。

## 已知边界（rc 版本）

- DSH `0.1.0-rc.6` API 无兼容承诺，升级需同步改插件。
- 插件连接建立前的事件会漏（App 用 `session.list` + `session.history` 补全量）。
- 冷会话读历史走 `sessionPersistence.readFrom`；`session.prompt` 对冷会话自动 `resume`。
