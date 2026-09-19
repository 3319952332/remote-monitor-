/**
 * Local notifications for session completion — no AGC/Push Kit required.
 * `publish` is callable while the app is foregrounded or briefly backgrounded
 * (short task grace); it posts to the notification tray.
 *
 * ArkTS note: NotificationKit API surface is version-sensitive; if DevEco
 * flags a field name, adjust per the SDK's NotificationRequest definition.
 */
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, wantAgent, WantAgent, Want } from '@kit.AbilityKit';
import { deviceKey, deviceLabel } from '../model/Device';

/** Deep-link route to one session, delivered by a question notification. */
interface SessionRoute {
  sessionId: string;
  nodeId: string;
}

export class NotificationService {
  private static nextId: number = 100;
  private static launchWantAgent: WantAgent | null = null;
  private static context: common.UIAbilityContext | null = null;

  /**
   * The device key delivered by the last notification tap (or want).
   * Reads AND clears so a single tap drives one page switch.
   */
  static pendingDeviceKey: string = '';

  /** Session route delivered by the last question-notification tap. */
  static pendingSessionId: string = '';
  static pendingNodeId: string = '';

  static consumePendingDeviceKey(): string {
    const v: string = NotificationService.pendingDeviceKey;
    NotificationService.pendingDeviceKey = '';
    return v;
  }

  /** Read-and-clear the pending session route (question notification deep link). */
  static consumePendingSessionRoute(): SessionRoute {
    const route: SessionRoute = {
      sessionId: NotificationService.pendingSessionId,
      nodeId: NotificationService.pendingNodeId,
    };
    NotificationService.pendingSessionId = '';
    NotificationService.pendingNodeId = '';
    return route;
  }

  /** 初始化：缓存"点击通知打开应用"的 WantAgent 及 context。 */
  static async init(context: common.UIAbilityContext): Promise<void> {
    NotificationService.context = context;
    try {
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      NotificationService.launchWantAgent = await wantAgent.getWantAgent(info);
    } catch (e) {
      console.error(`[notify] init wantAgent failed: ${JSON.stringify(e)}`);
    }
  }

  /** Ensure notification permission is granted (first use shows a dialog). */
  static async ensureEnabled(context: common.UIAbilityContext): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(context);
      }
    } catch (e) {
      console.error(`[notify] ensureEnabled failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * Post a "session completed" notification tagged with the source device
   * label; tapping the notification opens the app onto that device's tab.
   *
   * @param deviceLabel  display name for `【device】` (e.g. "laowang")
   * @param deviceKey    stable key for tab routing (e.g. "laowang@ubuntu")
   */
  static notifyCompletion(
    sessionId: string,
    turn: number,
    kind: string,
    deviceLabel: string = '',
    deviceKey: string = '',
  ): void {
    const short: string = sessionId.length > 8 ? sessionId.slice(-8) : sessionId;
    const prefix: string = deviceLabel.length > 0 ? `【${deviceLabel}】` : '';
    NotificationService.publish(
      '会话完成',
      `${prefix}会话 ${short} 回合 #${turn} 完成（${kind}）`,
      deviceKey,
    );
  }

  /** Post a "question needs answering" notification, deep-linked to the session. */
  static notifyQuestion(
    sessionId: string,
    nodeId: string,
    nodeName: string,
    hostname: string,
    questionText: string,
  ): void {
    const label: string = deviceLabel(nodeName, hostname);
    const key: string = deviceKey(nodeName, hostname);
    const q: string = questionText.length > 40 ? questionText.slice(0, 40) + '…' : questionText;
    NotificationService.publish(
      '问题待答复',
      `【${label}】${q}`,
      key,
      sessionId,
      nodeId,
    );
  }

  /** Build a per-notification wantAgent that carries deep-link params. */
  private static async buildWantAgent(
    deviceKey: string,
    sessionId: string = '',
    nodeId: string = '',
  ): Promise<WantAgent | null> {
    if (deviceKey.length === 0 && sessionId.length === 0) {
      return NotificationService.launchWantAgent;
    }
    const ctx: common.UIAbilityContext | null = NotificationService.context;
    if (ctx === null) {
      return NotificationService.launchWantAgent;
    }
    try {
      const params: Record<string, string> = {};
      if (deviceKey.length > 0) {
        params['deviceKey'] = deviceKey;
      }
      if (sessionId.length > 0) {
        params['sessionId'] = sessionId;
      }
      if (nodeId.length > 0) {
        params['nodeId'] = nodeId;
      }
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
        parameters: params,
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      return await wantAgent.getWantAgent(info);
    } catch (e) {
      console.error(`[notify] build wantAgent failed: ${JSON.stringify(e)}`);
      return NotificationService.launchWantAgent;
    }
  }

  /** Publish a basic-text tray notification, optionally deep-linked to a device tab and/or session. */
  static async publish(
    title: string,
    text: string,
    deviceKey: string = '',
    sessionId: string = '',
    nodeId: string = '',
  ): Promise<void> {
    try {
      const agent: WantAgent | null = await NotificationService.buildWantAgent(deviceKey, sessionId, nodeId);

      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text,
        },
      } as notificationManager.NotificationContent;

      const request: notificationManager.NotificationRequest = {
        id: NotificationService.nextId++,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: content,
        notificationFlags: {
          soundEnabled: 1,
          vibrationEnabled: 2,
          bannerEnabled: 1,
        },
        wantAgent: agent ?? undefined,
      } as notificationManager.NotificationRequest;

      notificationManager.publish(request, (err: BusinessError) => {
        if (err) {
          console.error(`[notify] publish failed: ${err.code} ${err.message}`);
        }
      });
    } catch (e) {
      console.error(`[notify] publish error: ${JSON.stringify(e)}`);
    }
  }
}