import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BackgroundTaskService } from '../services/BackgroundTaskService';
import { MonitorState } from '../services/MonitorState';
import { NotificationService } from '../services/NotificationService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // Ask for notification permission up front (foreground), so both the
    // continuous-task notice and session-completion notice can post later.
    BackgroundTaskService.ensureNotificationEnabled(this.context);
    NotificationService.init(this.context);
    MonitorState.init(this.context);
    this.captureDeviceKey(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.captureDeviceKey(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 主窗口创建，加载首页（登录页）
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/MonitorHome', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    MonitorState.setBackgrounded(false);
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // Keep the relay WebSocket alive while backgrounded.
    MonitorState.setBackgrounded(true);
  }

  private captureDeviceKey(want: Want): void {
    const params: Record<string, Object> = want.parameters as Record<string, Object>;
    const deviceKey: string = (params?.['deviceKey'] ?? '') as string;
    if (deviceKey.length > 0) {
      NotificationService.pendingDeviceKey = deviceKey;
    }
    const sessionId: string = (params?.['sessionId'] ?? '') as string;
    if (sessionId.length > 0) {
      NotificationService.pendingSessionId = sessionId;
    }
    const nodeId: string = (params?.['nodeId'] ?? '') as string;
    if (nodeId.length > 0) {
      NotificationService.pendingNodeId = nodeId;
    }
  }
}