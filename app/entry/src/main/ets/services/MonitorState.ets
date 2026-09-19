import { common } from '@kit.AbilityKit';
import { BackgroundTaskService } from './BackgroundTaskService';

/**
 * Global keepalive coordinator.
 *
 * The DATA_TRANSFER continuous task used to run for the whole time the app was
 * backgrounded, to keep the relay WebSocket alive. That is now deliberately
 * OFF: offline delivery is handled by Push Kit, so the app no longer needs to
 * hold a long-running background task (and the persistent notification that
 * comes with it).
 *
 * Consequence of disabling: once backgrounded, HarmonyOS eventually suspends
 * the process, the socket drops, and any `turn.end` arriving after that is
 * delivered as a push instead — which is exactly the intended behaviour. The
 * relay already treats "no client socket" as "app gone" and pushes.
 * `RelayClient.connect()` reconnects on the next foreground automatically.
 *
 * Set `KEEP_ALIVE_IN_BACKGROUND = true` to restore the old behaviour; the
 * `ohos.permission.KEEP_BACKGROUND_RUNNING` permission and the ability's
 * `backgroundModes: ["dataTransfer"]` declaration must be restored with it
 * (both were removed from module.json5 at the same time).
 */
const KEEP_ALIVE_IN_BACKGROUND: boolean = false;

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
    if (!KEEP_ALIVE_IN_BACKGROUND) {
      return;
    }
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
