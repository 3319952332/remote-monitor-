/**
 * Continuous Task (长时任务) helper for keeping the relay WebSocket alive while
 * the app is backgrounded. Requesting a DATA_TRANSFER continuous task raises
 * the process priority and keeps the socket + heartbeat running; HarmonyOS
 * publishes the mandatory ongoing notification itself (clicking it returns to
 * EntryAbility via the WantAgent).
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent, Want, common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';

export class BackgroundTaskService {
  private static wantAgentObj: WantAgent | null = null;
  private static running: boolean = false;

  /** Ensure notification permission is granted (system shows the ongoing task). */
  static async ensureNotificationEnabled(context: common.UIAbilityContext): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(context);
      }
    } catch (e) {
      console.error(`[bg] ensureNotificationEnabled failed: ${JSON.stringify(e)}`);
    }
  }

  /** Request a DATA_TRANSFER continuous task on entering background. */
  static async start(context: common.UIAbilityContext): Promise<void> {
    if (BackgroundTaskService.running) {
      return;
    }
    await BackgroundTaskService.ensureNotificationEnabled(context);
    try {
      if (BackgroundTaskService.wantAgentObj === null) {
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
        BackgroundTaskService.wantAgentObj = await wantAgent.getWantAgent(info);
      }
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        BackgroundTaskService.wantAgentObj,
      );
      BackgroundTaskService.running = true;
      console.info('[bg] continuous task started (DATA_TRANSFER)');
    } catch (e) {
      console.error(`[bg] startBackgroundRunning failed: ${JSON.stringify(e)}`);
    }
  }

  /** Release the continuous task on returning to foreground. */
  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (!BackgroundTaskService.running) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      console.info('[bg] continuous task stopped');
    } catch (e) {
      console.error(`[bg] stopBackgroundRunning failed: ${JSON.stringify(e)}`);
    }
    BackgroundTaskService.running = false;
  }
}
