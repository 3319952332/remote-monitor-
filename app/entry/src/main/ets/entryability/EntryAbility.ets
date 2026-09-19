import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BackgroundTaskService } from '../services/BackgroundTaskService';
import { DeviceIdService } from '../services/DeviceIdService';
import { MonitorState } from '../services/MonitorState';
import { NotificationService } from '../services/NotificationService';
import { PushTokenService } from '../services/PushTokenService';
import { relay } from '../services/RelayInstance';

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
    this.initIdentity();
    this.captureDeviceKey(want);
  }

  /**
   * Resolve the stable device id and the Push Token, then register both with
   * the relay. Ordering matters only for the very first hello — the relay keys
   * its push registry on the device id, so an id that arrives after the token
   * would briefly register the token under the display name instead, and the
   * re-hello issued by each setter corrects that immediately.
   *
   * The app does not connect here (that happens on the home page); these values
   * are simply in place before `relay.connect()` runs.
   */
  private async initIdentity(): Promise<void> {
    await DeviceIdService.init(this.context);
    relay.setDeviceId(DeviceIdService.get());
    // Push Kit: fetch the Push Token and hand it to the relay so it can notify
    // us while offline. Failure is non-fatal (app just can't get offline push).
    PushTokenService.init(this, (token: string) => relay.setPushToken(token));
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
    // Visible again: a completion event needs no push banner while we watch.
    relay.reportAppState(true);
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // Keep the relay WebSocket alive while backgrounded.
    MonitorState.setBackgrounded(true);
    // Tell the relay we are no longer looking, so a `turn.end` that arrives
    // now is pushed instead of silently broadcast to a hidden app.
    relay.reportAppState(false);
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