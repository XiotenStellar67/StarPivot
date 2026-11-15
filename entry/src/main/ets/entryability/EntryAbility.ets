import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    try {
      const mainWin: window.Window = windowStage.getMainWindowSync();
      mainWin.setWindowKeepScreenOn(true);
    } catch (e) {
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(0x0000, 'testTag', 'Succeeded in loading the content.');
    });

    // 去掉上下多余留白：窗口背景与页面同色，并让内容铺满整屏（系统栏区域由 expandSafeArea 处理背景）
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowBackgroundColor('#26262A');
      win.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(0x0000, 'testTag', 'window layout full screen ok');
      }).catch((e: Error) => {
        hilog.warn(0x0000, 'testTag', 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(e));
      });
      win.setWindowSystemBarProperties({
        statusBarColor: '#26262A',
        statusBarContentColor: '#F2F2F4',
        navigationBarColor: '#26262A',
        navigationBarContentColor: '#F2F2F4'
      });
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'window style setup failed: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
