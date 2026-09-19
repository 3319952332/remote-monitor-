/**
 * Push Kit token acquisition.
 *
 * The Push Token is a long-lived per-device/per-app string issued by Huawei.
 * The relay needs it to send offline notifications when this app's WebSocket
 * is not connected. We fetch it once at startup, keep it cached, and refresh
 * whenever the system announces a token change.
 *
 * Failure is non-fatal: without a token the app still works, it just cannot
 * receive offline pushes. All failure modes are logged with their error code
 * because the codes point straight at the AGC misconfiguration:
 *   1000900012  Push rights are not activated  → AGC 未开通推送服务
 *   1000900010  Illegal application identity   → client_id / 证书指纹 配置不对
 *   1000900011  The network is unavailable
 *   1000900014  The device does not support getting token
 */
import { pushService } from '@kit.PushKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import type { UIAbility } from '@kit.AbilityKit';

const DOMAIN = 0x0000;
const TAG = 'PushToken';

/** Error-code → human hint, for faster AGC troubleshooting. */
function hintFor(code: number): string {
  if (code === 1000900010) {
    return '应用身份不合法：检查 module.json5 的 client_id 与 AGC 公钥指纹';
  }
  if (code === 1000900011) {
    return '网络不可用';
  }
  if (code === 1000900012) {
    return '推送权益未开通：AGC 推送服务未对该应用生效';
  }
  if (code === 1000900013) {
    return '跨区域应用不允许获取 Token';
  }
  if (code === 1000900014) {
    return '本设备不支持获取 Push Token';
  }
  return '未知错误';
}

export class PushTokenService {
  private static token: string = '';
  private static initialized: boolean = false;
  private static pendingAbility: UIAbility | null = null;

  /** Last acquired token (empty when unavailable). */
  static getToken(): string {
    return PushTokenService.token;
  }

  static hasToken(): boolean {
    return PushTokenService.token.length > 0;
  }

  /**
   * Fetch the token and subscribe to token-update events. Safe to call more
   * than once. `onToken` fires whenever a token becomes available or changes,
   * so the caller can forward it to the relay.
   */
  static async init(ability: UIAbility, onToken?: (token: string) => void): Promise<void> {
    if (PushTokenService.initialized) {
      if (PushTokenService.token.length > 0 && onToken) {
        onToken(PushTokenService.token);
      }
      return;
    }
    PushTokenService.initialized = true;
    PushTokenService.pendingAbility = ability;

    // Token rotation: re-report so the server never keeps a stale token.
    try {
      pushService.on('tokenUpdate', ability, (newToken: string) => {
        hilog.info(DOMAIN, TAG, 'tokenUpdate: %{public}s', newToken);
        PushTokenService.token = newToken;
        if (onToken) {
          onToken(newToken);
        }
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'tokenUpdate 监听注册失败: %{public}d %{public}s', err.code, err.message);
    }

    try {
      hilog.info(DOMAIN, TAG, '开始获取 Push Token…');
      const token: string = await pushService.getToken();
      PushTokenService.token = token;
      hilog.info(DOMAIN, TAG, '✅ Push Token 获取成功（%{public}d 字符）: %{public}s',
        token.length, token);
      if (onToken) {
        onToken(token);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '❌ 获取 Push Token 失败: code=%{public}d msg=%{public}s | %{public}s',
        err.code, err.message, hintFor(err.code));
    }
  }
}
