import {
  GeneratedImageFrame,
  GeneratedPlantImage
} from '../model/GeneratedImageModels';
import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct GeneratedImageCard {
  @Prop item: GeneratedPlantImage = new GeneratedPlantImage();
  @Prop previewing: boolean = false;
  onPreview: (item: GeneratedPlantImage, sourceFrame: GeneratedImageFrame) => void =
    (_item: GeneratedPlantImage, _sourceFrame: GeneratedImageFrame) => {};
  onDelete: (item: GeneratedPlantImage) => void =
    (_item: GeneratedPlantImage) => {};
  onReuse: (item: GeneratedPlantImage) => void =
    (_item: GeneratedPlantImage) => {};

  @State private actionsVisible: boolean = false;
  private sourceLeft: number = 0;
  private sourceTop: number = 0;
  private sourceWidth: number = 0;
  private sourceHeight: number = 0;

  private sourceFrame(): GeneratedImageFrame {
    return new GeneratedImageFrame(
      this.sourceLeft,
      this.sourceTop,
      this.sourceWidth,
      this.sourceHeight
    );
  }

  private handleTap(): void {
    if (this.actionsVisible) {
      this.actionsVisible = false;
      return;
    }
    const frame = this.sourceFrame();
    if (frame.isUsable()) {
      this.onPreview(this.item, frame);
    }
  }

  private reuseImage(): void {
    this.actionsVisible = false;
    this.onReuse(this.item);
  }

  private deleteImage(): void {
    this.actionsVisible = false;
    this.onDelete(this.item);
  }

  @Builder
  private actionButton(symbol: string, title: string, destructive: boolean, action: () => void) {
    Button() {
      Column({ space: 4 }) {
        Text(symbol)
          .fontSize(20)
          .fontColor(destructive ? '#FFFF453A' : Color.White)
        Text(title)
          .fontSize(12)
          .fontColor(destructive ? '#FFFF453A' : Color.White)
      }
    }
    .layoutWeight(1)
    .height(64)
    .backgroundColor(Color.Transparent)
    .accessibilityText(title)
    .onClick(action)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Text('图片')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))

      Image(this.item.imageUri)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)

      if (this.actionsVisible) {
        Column() {
          Blank()
          Row() {
            this.actionButton('♧', '复用', false, () => this.reuseImage())
            Divider()
              .vertical(true)
              .height(34)
              .color('#66FFFFFF')
            this.actionButton('⌫', '删除', true, () => this.deleteImage())
          }
          .width('100%')
          .backgroundColor('#CC111111')
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .aspectRatio(1)
    .backgroundColor($r('app.color.background_secondary'))
    .borderRadius(DesignTokens.CORNER_CARD)
    .clip(true)
    .opacity(this.previewing ? 0 : 1)
    .accessibilityText('AI 生成图片')
    .accessibilityDescription('轻点放大，长按可复用到植物卡片或删除')
    .onAreaChange((_oldArea, newArea) => {
      this.sourceLeft = Number.parseFloat((newArea.globalPosition.x ?? 0).toString());
      this.sourceTop = Number.parseFloat((newArea.globalPosition.y ?? 0).toString());
      this.sourceWidth = Number.parseFloat(newArea.width.toString());
      this.sourceHeight = Number.parseFloat(newArea.height.toString());
    })
    .onClick(() => this.handleTap())
    .gesture(
      LongPressGesture({
        repeat: false,
        duration: 500
      })
        .onAction(() => {
          this.actionsVisible = true;
        })
    )
  }
}
