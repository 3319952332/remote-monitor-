/**
 * Push Kit v3 client for the relay.
 *
 * Auth: the service-account JWT goes straight into `Authorization: Bearer`.
 * HarmonyOS 5+ dropped OAuth2.0 access-token auth for downstream messages.
 *
 * JWT signing: measured against the live OAuth endpoint, only RS256
 * (PKCS1 v1.5) validates — PS256 is rejected with `jwt verify error`, despite
 * the official docs' PS256 samples.
 *
 * Request body follows the official v3 structure:
 *   { "payload": { "notification": {...} }, "target": { "token": [...] }, "pushOptions": {...} }
 * https://developer.huawei.com/consumer/cn/doc/harmonyos-references/push-scenariozed-api-request-struct
 */
import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";

const PUSH_HOST = "https://push-api.cloud.huawei.com";
const OAUTH_AUD = "https://oauth-login.cloud.huawei.com/oauth2/v3/token";

/** push-type values for the v3 endpoint. */
export const PUSH_TYPE = {
  ALERT: 0, // 通知消息 / 角标刷新
  FORM_UPDATE: 1, // 卡片刷新
  VOICE: 2, // 语音播报
  BACKGROUND: 6, // 后台消息
  LIVE_VIEW: 7, // 实况窗
  VOIP: 10, // 应用内通话
};

function b64url(buf) {
  return Buffer.from(buf)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

/** Sign a service-account JWT (RS256 / PKCS1 v1.5) for the Push API. */
export function buildJwt(serviceAccount, nowMs = Date.now()) {
  const now = Math.floor(nowMs / 1000);
  const header = { alg: "RS256", kid: serviceAccount.key_id, typ: "JWT" };
  const payload = {
    iss: serviceAccount.sub_account,
    aud: OAUTH_AUD,
    iat: now,
    exp: now + 3600, // official guidance: reuse within 1h
  };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const signer = createSign("sha256");
  signer.update(signingInput);
  // RS256 = PKCS1 v1.5 (default padding). Do NOT use PSS here.
  const signature = signer.sign(serviceAccount.private_key);
  return `${signingInput}.${b64url(signature)}`;
}

export function loadServiceAccount(path) {
  const sa = JSON.parse(readFileSync(path, "utf8"));
  for (const k of ["key_id", "private_key", "sub_account"]) {
    if (!sa[k]) throw new Error(`service account key missing field: ${k}`);
  }
  return sa;
}

/**
 * Build a v3 alert-message request body.
 *
 * `category` is the self-classification value (see PUSH_CATEGORY). Omitting it
 * makes Huawei classify the message as 资讯营销 (marketing) — delivered, but
 * shown silently and capped at 2–5/day.
 *
 * @param {{token:string,title:string,body:string,category?:string,
 *          testMessage?:boolean,ttl?:number,badge?:number,
 *          clickAction?:object,foregroundShow?:boolean}} opts
 */
export function buildAlertBody(opts) {
  const notification = {
    title: opts.title,
    body: opts.body,
    // clickAction 为必填：actionType 0 = 打开应用首页；1 = 打开应用内指定页面
    clickAction: opts.clickAction ?? { actionType: 0 },
  };
  if (opts.category) notification.category = opts.category;
  if (opts.badge !== undefined) notification.badge = { setNum: opts.badge };
  if (opts.foregroundShow !== undefined) notification.foregroundShow = opts.foregroundShow;

  const body = {
    payload: { notification },
    target: { token: [opts.token] },
  };

  // pushOptions is a top-level sibling of payload/target.
  const pushOptions = {};
  if (opts.testMessage === true) pushOptions.testMessage = true;
  if (opts.ttl !== undefined) pushOptions.ttl = opts.ttl;
  if (Object.keys(pushOptions).length > 0) body.pushOptions = pushOptions;

  if (opts.validateOnly === true) body.validate_only = true;
  return body;
}

/**
 * Send one alert message. Returns { ok, code, msg, requestId, raw }.
 * Never throws for API-level errors — callers only care about ok/code.
 */
export async function sendAlert(serviceAccount, projectId, opts, fetchImpl = fetch) {
  const jwt = buildJwt(serviceAccount);
  const url = `${PUSH_HOST}/v3/${projectId}/messages:send`;
  const res = await fetchImpl(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json;charset=utf-8",
      Authorization: `Bearer ${jwt}`,
      "push-type": String(opts.pushType ?? PUSH_TYPE.ALERT),
    },
    body: JSON.stringify(buildAlertBody(opts)),
  });
  const text = await res.text();
  let parsed = {};
  try {
    parsed = JSON.parse(text);
  } catch {
    /* non-JSON error page */
  }
  return {
    ok: res.ok && parsed.code === "80000000",
    status: res.status,
    code: parsed.code ?? "",
    msg: parsed.msg ?? text.slice(0, 200),
    requestId: parsed.requestId ?? "",
    raw: text,
  };
}

/** Notification categories (cloud `category` values). */
export const PUSH_CATEGORY = {
  /** 工作事项提醒 — 待办/工作提醒。提醒方式：锁屏+铃声+振动。需申请自分类权益。 */
  WORK: "WORK",
  IM: "IM",
  VOIP: "VOIP",
  TRAVEL: "TRAVEL",
  HEALTH: "HEALTH",
  ACCOUNT: "ACCOUNT",
  EXPRESS: "EXPRESS",
  FINANCE: "FINANCE",
  MAIL: "MAIL",
  SUBSCRIPTION: "SUBSCRIPTION",
  DEVICE_REMINDER: "DEVICE_REMINDER",
  /** 资讯营销 — 未申请权益时的默认归类：静默，2~5 条/日。 */
  MARKETING: "MARKETING",
};

export const PUSH_ERROR_HINTS = {
  "80100003": "请求体结构不合法（payload/target 字段缺失或位置错误）",
  "80200001": "鉴权失败：凭证未绑定推送服务 API，或 JWT/projectId 不匹配",
  "80200002": "项目未开通推送服务",
  "80300002": "无可用的目标 token",
  "80300007": "token 无效（可能已被 deleteToken 或卸载重装失效）",
  "80300008": "消息体过大",
  "80100000": "部分 token 发送失败",
};
