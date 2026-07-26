import { APP_THEME_OPTIONS, AppThemeOption } from '../theme/AppTheme';
import { DesignTokens } from '../theme/DesignTokens';

@Entry
@Component
struct AppSettingsPage {
  @StorageLink('appTheme') appTheme: string = 'blue';
  @StorageLink('reduceMotion') reduceMotion: boolean = false;

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private openAISettings(): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/AISettingsPage'
      });
    } catch (_error) {
      // Keep the settings page usable if navigation is temporarily unavailable.
    }
  }

  @Builder
  private header() {
    Row() {
      Button() {
        Text('‹')
          .fontSize(30)
          .fontColor($r('app.color.text_primary'))
      }
      .width(DesignTokens.TOUCH_TARGET)
      .height(DesignTokens.TOUCH_TARGET)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.goBack())

      Text('设置')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Blank()
    }
    .height(DesignTokens.TOOLBAR_HEIGHT)
    .padding({ left: 4, right: 16 })
  }

  @Builder
  private themeRow(option: AppThemeOption) {
    Row({ space: 12 }) {
      Circle()
        .width(18)
        .height(18)
        .fill(option.color)
      Text(option.title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (this.appTheme === option.id) {
        Text('✓')
          .fontSize(18)
          .fontColor(option.color)
      }
    }
    .height(48)
    .width('100%')
    .onClick(() => {
      this.appTheme = option.id;
    })
  }

  build() {
    Column() {
      this.header()

      Scroll() {
        Column({ space: 20 }) {
          Column() {
            Text('主题颜色')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .alignSelf(ItemAlign.Start)
              .padding({ left: 16, bottom: 6 })

            Column() {
              ForEach(APP_THEME_OPTIONS, (option: AppThemeOption) => {
                this.themeRow(option)
              }, (option: AppThemeOption) => option.id.toString())
            }
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.background_secondary'))
            .borderRadius(16)
          }

          Row({ space: 12 }) {
            Column({ space: 3 }) {
              Text('减弱动态效果')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('缩短横滑与展开动画，停止 Orb 循环呼吸')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Toggle({
              type: ToggleType.Switch,
              isOn: this.reduceMotion
            })
              .onChange((isOn: boolean) => {
                this.reduceMotion = isOn;
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .backgroundColor($r('app.color.background_secondary'))
          .borderRadius(16)

          Button() {
            Row() {
              Text('◉')
                .fontSize(18)
              Text('大模型设置')
                .fontSize(16)
              Blank()
              Text('›')
                .fontSize(20)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
          }
          .height(54)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.background_secondary'))
          .borderRadius(16)
          .onClick(() => this.openAISettings())

          Button() {
            Row({ space: 8 }) {
              Text('♲')
              Text('删除全部历史记录')
            }
          }
          .height(54)
          .fontColor($r('app.color.danger'))
          .backgroundColor($r('app.color.background_secondary'))
          .borderRadius(16)
          .enabled(false)
          .opacity(0.55)

          Text('数据库接入完成后启用删除操作；同步游标会按 iOS 端规则保留，避免 ESP32 把已删除数据重新下载。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_primary'))
  }
}
