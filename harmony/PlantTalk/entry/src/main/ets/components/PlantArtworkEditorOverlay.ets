import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct PlantArtworkEditorOverlay {
  @Prop hasArtwork: boolean = false;
  @Prop defaultPrompt: string = '';
  onChooseArtwork: () => void = () => {};
  onGenerateArtwork: (prompt: string) => void = (_prompt: string) => {};
  onRemoveArtwork: () => void = () => {};
  onDismiss: () => void = () => {};

  @State private prompt: string = '';

  aboutToAppear(): void {
    this.prompt = this.defaultPrompt;
  }

  private generate(): void {
    const value = this.prompt.trim();
    if (!this.hasArtwork || value.length === 0) {
      return;
    }
    this.onGenerateArtwork(value);
  }

  @Builder
  private actionButton(
    title: string,
    enabled: boolean,
    destructive: boolean,
    action: () => void
  ) {
    Button(title)
      .width('100%')
      .height(46)
      .fontSize(15)
      .fontColor(destructive ? '#FFFF453A' : $r('app.color.text_primary'))
      .backgroundColor($r('app.color.background_secondary'))
      .enabled(enabled)
      .opacity(enabled ? 1 : 0.45)
      .onClick(() => {
        if (enabled) {
          action();
        }
      })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#73000000')
        .onClick(() => this.onDismiss())

      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Column({ space: 3 }) {
              Text('植物图片')
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('选择照片后可用当前提示词生成新的植物插画')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button('完成')
              .height(38)
              .backgroundColor(Color.Transparent)
              .fontColor('#FF0A84FF')
              .onClick(() => this.onDismiss())
          }
          .width('100%')

          this.actionButton(
            this.hasArtwork ? '选择新图片或拍照' : '选择图片或拍照',
            true,
            false,
            () => this.onChooseArtwork()
          )

          Text('AI 生图提示词')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .alignSelf(ItemAlign.Start)

          TextArea({
            text: this.prompt,
            placeholder: '描述希望生成的植物插画'
          })
            .width('100%')
            .height(132)
            .padding(14)
            .fontSize(15)
            .backgroundColor($r('app.color.background_secondary'))
            .borderRadius(DesignTokens.CORNER_ROW)
            .onChange((value: string) => {
              this.prompt = value;
            })

          Button('AI 生图')
            .width('100%')
            .height(48)
            .enabled(this.hasArtwork && this.prompt.trim().length > 0)
            .opacity(this.hasArtwork && this.prompt.trim().length > 0 ? 1 : 0.45)
            .onClick(() => this.generate())

          if (this.hasArtwork) {
            this.actionButton(
              '恢复默认插画',
              true,
              true,
              () => this.onRemoveArtwork()
            )
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 18, bottom: 32 })
      }
      .width('100%')
      .constraintSize({ maxHeight: '78%' })
      .backgroundColor($r('app.color.background_primary'))
      .borderRadius({
        topLeft: DesignTokens.CORNER_SHEET,
        topRight: DesignTokens.CORNER_SHEET
      })
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .zIndex(50)
  }
}
