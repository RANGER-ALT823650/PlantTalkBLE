import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct HistoryOverviewPage {
  onBack: () => void = () => {};

  @Builder
  private emptyState(symbol: string, title: string, detail: string) {
    Column({ space: 12 }) {
      Text(symbol)
        .fontSize(42)
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(detail)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 32, right: 32 })
  }

  @Builder
  private header() {
    Row() {
      Text('历史记录')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Button() {
        Text('×')
          .fontSize(25)
          .fontColor($r('app.color.text_primary'))
      }
      .width(DesignTokens.TOUCH_TARGET)
      .height(DesignTokens.TOUCH_TARGET)
      .backgroundColor(Color.Transparent)
      .onClick(this.onBack)
    }
    .height(DesignTokens.TOOLBAR_HEIGHT)
    .padding({ left: 20, right: 12 })
  }

  build() {
    Column() {
      this.header()

      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
          Column() {
            Blank().layoutWeight(1)
            this.emptyState('⌁', '暂无传感器历史', '连接 Plant Sensor 后，五分钟采样记录会显示在这里。')
            Blank().layoutWeight(1)
          }
          .width('100%')
          .height('100%')
        }
        .tabBar('传感器')

        TabContent() {
          Column() {
            Blank().layoutWeight(1)
            this.emptyState('▤', '暂无文字对话', '从主页输入一句话，开始与植物聊天。')
            Blank().layoutWeight(1)
          }
          .width('100%')
          .height('100%')
        }
        .tabBar('文字对话')

        TabContent() {
          Column() {
            Blank().layoutWeight(1)
            this.emptyState('≋', '暂无实时语音', '点击主页底部的 Orb，开始实时语音对话。')
            Blank().layoutWeight(1)
          }
          .width('100%')
          .height('100%')
        }
        .tabBar('实时语音')
      }
      .layoutWeight(1)
      .barMode(BarMode.Fixed)
      .scrollable(false)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_primary'))
  }
}
