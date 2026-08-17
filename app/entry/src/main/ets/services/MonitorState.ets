import { common } from '@kit.AbilityKit';
import { BackgroundTaskService } from './BackgroundTaskService';

/**
 * Global keepalive coordinator: the DATA_TRANSFER continuous task runs for the
 * whole time the app is backgrounded — no turn-activity gating. Entering the
 * background starts keepalive; returning to the foreground stops it.
 */
export class MonitorState {
  private static backgrounded: boolean = false;
  private static context: common.UIAbilityContext | null = null;

  static init(context: common.UIAbilityContext): void {
    MonitorState.context = context;
  }

  static setBackgrounded(backgrounded: boolean): void {
    if (MonitorState.backgrounded === backgrounded) {
      return;
    }
    MonitorState.backgrounded = backgrounded;
    MonitorState.apply();
  }

  private static apply(): void {
    if (MonitorState.context === null) {
      return;
    }
    if (MonitorState.backgrounded) {
      BackgroundTaskService.start(MonitorState.context);
    } else {
      BackgroundTaskService.stop(MonitorState.context);
    }
  }
}
