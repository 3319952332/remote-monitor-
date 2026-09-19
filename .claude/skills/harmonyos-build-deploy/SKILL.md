# HarmonyOS App 构建与部署

## 适用场景

本项目 `dsh-remote`（DSH 远程监控）包含鸿蒙 App、DSH 插件、relay 中转服务器三部分。
每次修改 App 代码（`app/entry/src/main/ets/`）或插件代码（`plugin/lib/index.js`）后按以下流程打包部署。

---

## 一、App 构建安装（鸿蒙端）

### 前置条件

- DevEco Studio SDK 安装于 `D:\Huawei\DevEco Studio\sdk`
- 设备：HUAWEI Mate 60 Pro+，通过 WiFi 连接 hdc
- 两个 App 共存，不能覆盖：
  - `com.example.aitest` = 文件管家（用户原有，绝不动）
  - `com.dsh.remote.monitor` = DSH 监控（本项目）

### 步骤

```powershell
cd E:\Code\Huawei\dsh-remote\app

# 1. 生成 RelayConfig.ets（从 relay-config.local.json 读取真实配置）
node gen-relay-config.mjs

# 2. 确保 hdc 已连接设备
& "D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" list targets
# 如果无设备，连接：
& "D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" tconn 192.168.31.214:41447

# 3. 构建 + 签名 + 安装 + 启动
$env:DEVECO_SDK_HOME = "D:\Huawei\DevEco Studio\sdk"
devecocli run --module entry --build-mode debug
```

### 常见问题

| 问题 | 解决 |
|------|------|
| `No active devices found` | hdc 没连上设备，重新 `hdc tconn` |
| `Connect failed` | 重试一次，hdc 有时首次连接失败 |
| `10106102: screen is locked` | 开发者模式下无法自动解锁，手动打开 App 即可（App 已安装） |
| `ArkTS Compiler Error` | 按错误提示修正代码，常见：对象不能再展开（`arkts-no-spread`）、内联对象类型不被允许（`arkts-no-obj-literals-as-types`）、`Select` 组件没有 `fontSize` 属性 |

### ArkTS 注意事项

- **对象不能展开**：`{ ...obj, extra: 1 }` 不允许，必须显式列出所有字段构造新对象
- **接口内联对象类型**：`{ a: string; b: number }` 不能直接用作类型，需要 `export interface Foo { ... }`
- **Select 组件**：没有 `fontSize` 属性，可使用 `font({ size: 14 })` 或无样式
- **SymbolGlyph**：`$r('sys.symbol.copy')` 可能不存在，用 emoji 兜底（如 `📋`）
- **copyOption**：`Text.copyOption(CopyOptions.LocalDevice)` 启用文本选择+复制
- **layoutWeight**：`Row` 内子组件用 `layoutWeight(1)` 等分剩余空间

---

## 二、插件部署

### 本地节点（my-dsh）

```powershell
# 1. 语法检查
node --check "E:\Code\Huawei\dsh-remote\plugin\lib\index.js"

# 2. 复制到新版本（N 递增，当前最新 v16）
$dst = "$env:USERPROFILE\.dsh\profiles\node_modules\dsh-remote-monitor-vN"
Copy-Item -Recurse -Force "E:\Code\Huawei\dsh-remote\plugin" $dst

# 3. 更新 cordis.patch.yml（name 改为 vN）
# 编辑 ~/.dsh/profiles/web/cordis.patch.yml

# 4. 清理旧版本
Remove-Item -Recurse -Force "$env:USERPROFILE\.dsh\profiles\node_modules\dsh-remote-monitor-v{old}"
```

### 远程节点（laowang，IP: 192.168.1.4）

```powershell
# 1. 复制插件到远程
scp -r "E:\Code\Huawei\dsh-remote\plugin" 192.168.1.4:/tmp/dsh-remote-monitor-vN

# 2. SSH 移动 + 更新 cordis.patch.yml + 清理旧版本
ssh 192.168.1.4 "mv /tmp/dsh-remote-monitor-vN ~/.dsh/profiles/node_modules/dsh-remote-monitor-vN && sed -i 's/dsh-remote-monitor-v{old}/dsh-remote-monitor-vN/' ~/.dsh/profiles/web/cordis.patch.yml && rm -rf ~/.dsh/profiles/node_modules/dsh-remote-monitor-v{old} && echo 'done'"
```

### 热加载验证

DSH 检测到 `cordis.patch.yml` 变更后会自动热加载。查看 relay 日志确认：

```powershell
ssh 111.229.53.125 "sudo journalctl -u dsh-relay --no-pager -n 10 | grep 'node online'"
```

应看到 `node online: my-dsh@...` 和 `node online: laowang@...` 带着新的 nodeId（说明重连成功）。

---

## 三、Relay 服务器部署

```powershell
# 1. 复制 relay 源码到服务器
scp "E:\Code\Huawei\dsh-remote\relay\src\protocol.js" "E:\Code\Huawei\dsh-remote\relay\src\index.js" 111.229.53.125:/tmp/

# 2. SSH 部署 + 重启
ssh 111.229.53.125 "sudo cp /tmp/protocol.js /home/ubuntu/dsh-relay/src/protocol.js && sudo cp /tmp/index.js /home/ubuntu/dsh-relay/src/index.js && sudo systemctl restart dsh-relay && echo 'restarted'"

# 3. 验证节点重连
ssh 111.229.53.125 "sudo journalctl -u dsh-relay --no-pager -n 10"
```

---

## 四、Relay 测试验证

用本地 node 脚本直接连 relay 测试方法：

```powershell
cd E:\Code\Huawei\dsh-remote\relay
node -e "
const WebSocket = require('ws');
const w = new WebSocket('wss://console.sub.opengm.top');
w.on('open', () => {
  w.send(JSON.stringify({v:1,type:'hello',role:'client',token:'<TOKEN>',deviceName:'test'}));
  setTimeout(() => w.send(JSON.stringify({v:1,type:'request',id:'r1',method:'session.list',params:{}})), 1000);
});
w.on('message', m => console.log(m.toString()));
"
```

---

## 五、关键配置与路径

| 项目 | 路径/值 |
|------|--------|
| 项目根目录 | `E:\Code\Huawei\dsh-remote` |
| App 源码 | `app/entry/src/main/ets/` |
| 插件源码 | `plugin/lib/index.js` |
| Relay 源码 | `relay/src/` |
| 本地 relay 配置 | `app/relay-config.local.json`（不提交 git） |
| 生成的 relay 配置 | `app/entry/src/main/ets/services/RelayConfig.ets`（gitignore） |
| DSH 插件目录 | `~/.dsh/profiles/node_modules/dsh-remote-monitor-vN` |
| DSH patch 配置 | `~/.dsh/profiles/web/cordis.patch.yml` |
| 远程 relay 服务 | `systemctl` 管理，位于 `/home/ubuntu/dsh-relay/` |
| 远程 relay 服务器 | `111.229.53.125`（SSH: ubuntu, key: `~/.ssh/CouldServer_1.pem`） |
| 远程 laowang 节点 | `192.168.1.4`（SSH: laowang, key: `~/.ssh/id_rsa_self`） |
| 设备 IP:端口 | `192.168.31.214:41447` |
| Relay 地址 | `wss://console.sub.opengm.top` |
| Relay Token | 在 `app/relay-config.local.json` 中 |