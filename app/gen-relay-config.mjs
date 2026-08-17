/**
 * 生成 entry/src/main/ets/services/RelayConfig.ets。
 *
 * 从 app/relay-config.local.json（本地文件，不进 git）读取真实连接配置；
 * 文件不存在时生成占位符版本，便于 clone 后仍能编译。
 *
 * 部署/构建前运行：node gen-relay-config.mjs
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const configPath = join(here, "relay-config.local.json");
const outPath = join(here, "entry", "src", "main", "ets", "services", "RelayConfig.ets");

let relayUrl = "ws://<YOUR_LAN_IP>:8787";
let token = "<YOUR_TOKEN>";

try {
  const cfg = JSON.parse(readFileSync(configPath, "utf8"));
  if (typeof cfg.relayUrl === "string" && cfg.relayUrl.length > 0) relayUrl = cfg.relayUrl;
  if (typeof cfg.token === "string" && cfg.token.length > 0) token = cfg.token;
  console.log(`[relay-config] 已读取 ${configPath}`);
} catch (e) {
  if (e.code !== "ENOENT") {
    console.error(`[relay-config] 配置文件解析失败: ${e.message}`);
    process.exit(1);
  }
  console.log(`[relay-config] 未找到 ${configPath}，生成占位符配置`);
}

const content = `// 由 gen-relay-config.mjs 自动生成，请勿手改；真实配置请改 relay-config.local.json
export const RELAY_URL: string = '${relayUrl}';
export const RELAY_TOKEN: string = '${token}';
`;

writeFileSync(outPath, content, "utf8");
console.log(`[relay-config] 已生成 ${outPath}`);
