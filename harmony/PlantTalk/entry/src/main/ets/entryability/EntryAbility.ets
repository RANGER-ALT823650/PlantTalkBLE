import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x504C;
const TAG: string = 'PlantTalkEntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('appTheme', 'blue');
    AppStorage.setOrCreate('reduceMotion', false);
    hilog.info(DOMAIN, TAG, 'Plant Talk created');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code !== 0) {
        hilog.error(
          DOMAIN,
          TAG,
          'Failed to load Plant Talk. Code: %{public}d, message: %{public}s',
          error.code,
          error.message
        );
      }
    });
  }

  onConfigurationUpdate(configuration: Configuration): void {
    AppStorage.setOrCreate('colorMode', configuration.colorMode);
  }
}
