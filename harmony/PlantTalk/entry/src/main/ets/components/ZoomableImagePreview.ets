import {
  GeneratedImageFrame,
  GeneratedImagePreviewItem
} from '../model/GeneratedImageModels';

@Component
export struct ZoomableImagePreview {
  @StorageLink('reduceMotion') reduceMotion: boolean = false;
  @Prop item: GeneratedImagePreviewItem = new GeneratedImagePreviewItem();
  onDismiss: () => void = () => {};

  @State private progress: number = 0;
  @State private viewportWidth: number = 0;
  @State private viewportHeight: number = 0;
  @State private viewportLeft: number = 0;
  @State private viewportTop: number = 0;
  private morphStarted: boolean = false;
  private dismissing: boolean = false;

  private clampedProgress(): number {
    return Math.max(0, Math.min(this.progress, 1));
  }

  private interpolate(start: number, end: number): number {
    return start + (end - start) * this.clampedProgress();
  }

  private localSourceFrame(): GeneratedImageFrame {
    const frame = this.item.sourceFrame;
    if (!frame.isUsable()) {
      const side = Math.min(this.viewportWidth, this.viewportHeight) * 0.36;
      return new GeneratedImageFrame(
        (this.viewportWidth - side) / 2,
        (this.viewportHeight - side) / 2,
        side,
        side
      );
    }
    return new GeneratedImageFrame(
      frame.left - this.viewportLeft,
      frame.top - this.viewportTop,
      frame.width,
      frame.height
    );
  }

  private destinationFrame(): GeneratedImageFrame {
    const availableWidth = Math.max(this.viewportWidth * 0.88, 1);
    const availableHeight = Math.max(this.viewportHeight * 0.88, 1);
    const source = this.localSourceFrame();
    const fallbackRatio = source.height > 0 ? source.width / source.height : 1;
    const imageRatio = this.item.image.aspectRatio(fallbackRatio);

    let width = availableWidth;
    let height = width / imageRatio;
    if (height > availableHeight) {
      height = availableHeight;
      width = height * imageRatio;
    }

    return new GeneratedImageFrame(
      (this.viewportWidth - width) / 2,
      (this.viewportHeight - height) / 2,
      width,
      height
    );
  }

  private currentLeft(): number {
    return this.interpolate(this.localSourceFrame().left, this.destinationFrame().left);
  }

  private currentTop(): number {
    return this.interpolate(this.localSourceFrame().top, this.destinationFrame().top);
  }

  private currentWidth(): number {
    return Math.max(
      this.interpolate(this.localSourceFrame().width, this.destinationFrame().width),
      1
    );
  }

  private currentHeight(): number {
    return Math.max(
      this.interpolate(this.localSourceFrame().height, this.destinationFrame().height),
      1
    );
  }

  private currentCornerRadius(): number {
    return this.interpolate(this.item.sourceCornerRadius, 0);
  }

  private startMorph(): void {
    if (this.morphStarted || this.viewportWidth <= 0 || this.viewportHeight <= 0) {
      return;
    }
    this.morphStarted = true;
    this.progress = 0;
    this.getUIContext().animateTo({
      duration: this.reduceMotion ? 180 : 420,
      curve: Curve.EaseInOut
    }, () => {
      this.progress = 1;
    });
  }

  private dismiss(): void {
    if (this.dismissing) {
      return;
    }
    this.dismissing = true;
    this.getUIContext().animateTo({
      duration: this.reduceMotion ? 180 : 420,
      curve: Curve.EaseInOut,
      onFinish: () => {
        this.onDismiss();
      }
    }, () => {
      this.progress = 0;
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(Color.Black)
        .opacity(this.clampedProgress() * 0.72)

      Image(this.item.image.imageUri)
        .width(this.currentWidth())
        .height(this.currentHeight())
        .objectFit(ImageFit.Cover)
        .borderRadius(this.currentCornerRadius())
        .position({
          x: this.currentLeft(),
          y: this.currentTop()
        })
        .shadow({
          radius: this.clampedProgress() * 12,
          color: '#33000000',
          offsetY: this.clampedProgress() * 4
        })
        .accessibilityText('图片预览')
        .accessibilityDescription('轻点关闭预览')
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea, newArea) => {
      this.viewportWidth = Number.parseFloat(newArea.width.toString());
      this.viewportHeight = Number.parseFloat(newArea.height.toString());
      this.viewportLeft = Number.parseFloat((newArea.globalPosition.x ?? 0).toString());
      this.viewportTop = Number.parseFloat((newArea.globalPosition.y ?? 0).toString());
      this.startMorph();
    })
    .onClick(() => this.dismiss())
  }
}
