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

export class NotificationService {
  private static nextId: number = 100;
  private static launchWantAgent: WantAgent | null = null;

  /** 初始化：缓存"点击通知打开应用"的 WantAgent。 */
  static async init(context: common.UIAbilityContext): Promise<void> {
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

  /** Post a "session completed" notification. */
  static notifyCompletion(sessionId: string, turn: number, kind: string): void {
    const short: string = sessionId.length > 8 ? sessionId.slice(-8) : sessionId;
    NotificationService.publish('会话完成', `会话 ${short} 回合 #${turn} 完成（${kind}）`);
  }

  /** Publish a basic-text tray notification. */
  static publish(title: string, text: string): void {
    try {
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
          soundEnabled: 2,
          vibrationEnabled: 2,
          bannerEnabled: 1,
        },
        wantAgent: NotificationService.launchWantAgent ?? undefined,
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
