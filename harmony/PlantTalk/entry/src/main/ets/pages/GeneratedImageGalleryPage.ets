import { GeneratedImageCard } from '../components/GeneratedImageCard';
import {
  GeneratedImageFrame,
  GeneratedPlantImage
} from '../model/GeneratedImageModels';
import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct GeneratedImageGalleryPage {
  @Prop images: GeneratedPlantImage[] = [];
  @Prop isLoading: boolean = false;
  onRefresh: () => void = () => {};
  onDelete: (item: GeneratedPlantImage) => void =
    (_item: GeneratedPlantImage) => {};
  onReuse: (item: GeneratedPlantImage) => void =
    (_item: GeneratedPlantImage) => {};
  @Prop previewingImageId: string = '';
  onPreview: (item: GeneratedPlantImage, sourceFrame: GeneratedImageFrame) => void =
    (_item: GeneratedPlantImage, _sourceFrame: GeneratedImageFrame) => {};

  @State private refreshing: boolean = false;

  private requestRefresh(): void {
    try {
      this.onRefresh();
    } finally {
      this.refreshing = false;
    }
  }

  @Builder
  private loadingState() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(30)
        .height(30)
      Text('正在读取 AI 图片…')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
  }

  @Builder
  private emptyState() {
    Column({ space: 12 }) {
      Text('✦')
        .fontSize(42)
      Text('还没有 AI 生成图片')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('在植物图片编辑页使用“AI 生图”后，结果会出现在这里。')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
      Button('刷新')
        .height(40)
        .fontSize(14)
        .onClick(() => {
          this.refreshing = true;
          this.requestRefresh();
        })
    }
    .width('100%')
    .padding({ left: 32, right: 32 })
  }

  @Builder
  private gallery() {
    Grid() {
      ForEach(
        this.images,
        (item: GeneratedPlantImage) => {
          GridItem() {
            GeneratedImageCard({
              item: item,
              previewing: this.previewingImageId === item.id,
              onPreview: (
                selectedItem: GeneratedPlantImage,
                sourceFrame: GeneratedImageFrame
              ) => this.onPreview(selectedItem, sourceFrame),
              onDelete: (selectedItem: GeneratedPlantImage) => this.onDelete(selectedItem),
              onReuse: (selectedItem: GeneratedPlantImage) => this.onReuse(selectedItem)
            })
          }
        },
        (item: GeneratedPlantImage) => item.id
      )
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(DesignTokens.GRID_SPACING)
    .rowsGap(DesignTokens.GRID_SPACING)
    .padding(16)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  build() {
    Refresh({
      refreshing: $$this.refreshing,
      promptText: '下拉刷新 AI 图片'
    }) {
      Column() {
        if (this.isLoading) {
          Blank().layoutWeight(1)
          this.loadingState()
          Blank().layoutWeight(1)
        } else if (this.images.length === 0) {
          Blank().layoutWeight(1)
          this.emptyState()
          Blank().layoutWeight(1)
        } else {
          this.gallery()
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .onRefreshing(() => this.requestRefresh())
    .backgroundColor($r('app.color.background_primary'))
  }
}
