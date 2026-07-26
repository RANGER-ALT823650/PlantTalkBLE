import { GeneratedImageGalleryPage } from './GeneratedImageGalleryPage';
import { ZoomableImagePreview } from '../components/ZoomableImagePreview';
import {
  GeneratedImageFrame,
  GeneratedImagePreviewItem,
  GeneratedPlantImage
} from '../model/GeneratedImageModels';
import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct HistoryOverviewPage {
  @Prop generatedImages: GeneratedPlantImage[] = [];
  @Prop isLoadingGeneratedImages: boolean = false;
  onBack: () => void = () => {};
  onRefreshGeneratedImages: () => void = () => {};
  onDeleteGeneratedImage: (item: GeneratedPlantImage) => void =
    (_item: GeneratedPlantImage) => {};
  onReuseGeneratedImage: (item: GeneratedPlantImage) => void =
    (_item: GeneratedPlantImage) => {};

  @State private pendingDeleteImage: GeneratedPlantImage | null = null;
  @State private previewVisible: boolean = false;
  @State private previewItem: GeneratedImagePreviewItem =
    new GeneratedImagePreviewItem();

  private presentGeneratedImagePreview(
    item: GeneratedPlantImage,
    sourceFrame: GeneratedImageFrame
  ): void {
    this.previewItem = new GeneratedImagePreviewItem(
      item,
      sourceFrame,
      DesignTokens.CORNER_CARD
    );
    this.previewVisible = true;
  }

  private requestGeneratedImageDeletion(item: GeneratedPlantImage): void {
    this.pendingDeleteImage = item;
  }

  private cancelGeneratedImageDeletion(): void {
    this.pendingDeleteImage = null;
  }

  private confirmGeneratedImageDeletion(): void {
    const item = this.pendingDeleteImage;
    if (item === null) {
      return;
    }
    this.pendingDeleteImage = null;
    this.onDeleteGeneratedImage(item);
  }

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

  @Builder
  private deleteConfirmation() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#73000000')

      Column({ space: 18 }) {
        Column({ space: 8 }) {
          Text('删除这张 AI 图片？')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('删除后无法恢复。')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .backgroundColor($r('app.color.background_secondary'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => this.cancelGeneratedImageDeletion())
          Button('删除')
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#FFFF453A')
            .fontColor(Color.White)
            .onClick(() => this.confirmGeneratedImageDeletion())
        }
        .width('100%')
      }
      .width('84%')
      .constraintSize({ maxWidth: 420 })
      .padding(22)
      .backgroundColor($r('app.color.background_primary'))
      .borderRadius(DesignTokens.CORNER_CARD)
      .shadow({
        radius: 28,
        color: '#33000000',
        offsetX: 0,
        offsetY: 10
      })
    }
    .width('100%')
    .height('100%')
    .zIndex(30)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
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

          TabContent() {
            GeneratedImageGalleryPage({
              images: this.generatedImages,
              isLoading: this.isLoadingGeneratedImages,
              onRefresh: () => this.onRefreshGeneratedImages(),
              onDelete: (item: GeneratedPlantImage) =>
                this.requestGeneratedImageDeletion(item),
              onReuse: (item: GeneratedPlantImage) =>
                this.onReuseGeneratedImage(item),
              previewingImageId: this.previewVisible ? this.previewItem.image.id : '',
              onPreview: (
                item: GeneratedPlantImage,
                sourceFrame: GeneratedImageFrame
              ) => this.presentGeneratedImagePreview(item, sourceFrame)
            })
          }
          .tabBar('AI 图片')
        }
        .layoutWeight(1)
        .barMode(BarMode.Fixed)
        .scrollable(false)
      }
      .width('100%')
      .height('100%')

      if (this.pendingDeleteImage !== null) {
        this.deleteConfirmation()
      }

      if (this.previewVisible) {
        ZoomableImagePreview({
          item: this.previewItem,
          onDismiss: () => {
            this.previewVisible = false;
          }
        })
          .width('100%')
          .height('100%')
          .zIndex(40)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_primary'))
  }
}
