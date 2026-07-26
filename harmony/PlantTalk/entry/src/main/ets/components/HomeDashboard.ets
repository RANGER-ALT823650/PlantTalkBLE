import curves from '@ohos.curves';
import { VoiceVisualAccentKind } from '../audio/VoiceVisualDriver';
import { PlantReading } from '../model/PlantModels';
import { accentColorFor, accentColorWithAlpha } from '../theme/AppTheme';
import { DesignTokens } from '../theme/DesignTokens';
import { DiffuseOrbFallback } from './DiffuseOrbFallback';
import { SensorMetricCard, SensorMetricViewModel } from './SensorMetricCard';

@Component
export struct HomeDashboard {
  @StorageLink('appTheme') appTheme: string = 'blue';
  @StorageLink('reduceMotion') reduceMotion: boolean = false;
  @Prop reading: PlantReading | null = null;
  @Prop bluetoothStatus: string = '未连接';
  @Prop bluetoothConnected: boolean = false;
  @Prop interactionSuppressed: boolean = false;
  @Prop motionPaused: boolean = false;
  @Prop artworkUri: string = '';
  @Prop isGeneratingArtwork: boolean = false;
  @Prop voiceLevel: number = 0;
  @Prop accentKind: VoiceVisualAccentKind = VoiceVisualAccentKind.NONE;
  @Prop accentIntensity: number = 0;
  @Prop accentSequence: number = 0;
  onOpenHistory: () => void = () => {};
  onToggleBluetooth: () => void = () => {};
  onOpenSettings: () => void = () => {};
  onSendText: (message: string) => void = () => {};
  onOpenRealtime: () => void = () => {};
  onEditArtwork: () => void = () => {};
  onCancelArtworkGeneration: () => void = () => {};

  @State private detailsExpanded: boolean = false;
  @State private draft: string = '';
  @State private contentWidth: number = 360;
  @State private contentHeight: number = 700;

  private layoutWidth(): number {
    return Math.min(this.contentWidth, DesignTokens.CONTENT_MAX_WIDTH);
  }

  private isCompactCoverScreen(): boolean {
    return this.contentWidth <= 350 && this.contentHeight <= 360;
  }

  private artworkWidth(): number {
    const usableWidth = this.layoutWidth() * (1 - DesignTokens.PAGE_HORIZONTAL_RATIO * 2);
    const widthDriven = usableWidth * (
      this.detailsExpanded
        ? DesignTokens.ARTWORK_EXPANDED_RATIO
        : DesignTokens.ARTWORK_COLLAPSED_RATIO
    );
    const expandedHeightRatio =
      this.isCompactCoverScreen() && this.detailsExpanded ? 0.38 : 0.25;
    const heightDriven = this.contentHeight * (
      this.detailsExpanded ? expandedHeightRatio : 0.42
    );
    return Math.max(0, Math.min(widthDriven, heightDriven));
  }

  private artworkEditButtonSize(): number {
    return this.isCompactCoverScreen() && this.detailsExpanded ? 32 : 40;
  }

  private artworkEditButtonInset(): number {
    return this.isCompactCoverScreen() && this.detailsExpanded ? 6 : 10;
  }

  private orbWidth(): number {
    const usableWidth = this.layoutWidth() * (1 - DesignTokens.PAGE_HORIZONTAL_RATIO * 2);
    return Math.max(0, Math.min(
      usableWidth * DesignTokens.ORB_WIDTH_RATIO,
      this.contentHeight * 0.22
    ));
  }

  private submitDraft(): void {
    const message = this.draft.trim();
    if (message.length === 0 || this.interactionSuppressed) {
      return;
    }
    this.draft = '';
    this.onSendText(message);
  }

  private toggleDetails(): void {
    if (this.interactionSuppressed || this.isGeneratingArtwork) {
      return;
    }
    this.getUIContext().animateTo({
      duration: this.reduceMotion ? 200 : 420,
      curve: this.reduceMotion ? Curve.EaseInOut : curves.springMotion(0.42, 1.0)
    }, () => {
      this.detailsExpanded = !this.detailsExpanded;
    });
  }

  private temperatureMetric(): SensorMetricViewModel {
    return new SensorMetricViewModel(
      '温度',
      this.reading?.temperature !== null && this.reading?.temperature !== undefined
        ? this.reading.temperature.toFixed(1)
        : '--',
      '°C',
      '🌡',
      $r('app.color.sensor_temperature')
    );
  }

  private humidityMetric(): SensorMetricViewModel {
    return new SensorMetricViewModel(
      '空气湿度',
      this.reading?.humidity !== null && this.reading?.humidity !== undefined
        ? this.reading.humidity.toFixed(1)
        : '--',
      '%',
      '💧',
      $r('app.color.sensor_humidity')
    );
  }

  private soilMetric(): SensorMetricViewModel {
    return new SensorMetricViewModel(
      '土壤湿度',
      this.reading === null ? '--' : `${this.reading.soilRaw}`,
      'ADC',
      '◉',
      $r('app.color.sensor_soil')
    );
  }

  private lightMetric(): SensorMetricViewModel {
    let value = '--';
    let unit = '';
    if (this.reading !== null) {
      if (this.reading.lightLux === null) {
        value = '未接入';
      } else {
        value = this.reading.lightLux.toFixed(0);
        unit = 'lx';
      }
    }
    return new SensorMetricViewModel(
      '光照',
      value,
      unit,
      '☀',
      $r('app.color.sensor_light')
    );
  }

  @Builder
  private toolbarButton(symbol: string, label: string, action: () => void) {
    Button() {
      Text(symbol)
        .fontSize(20)
        .fontColor($r('app.color.text_primary'))
    }
    .width(DesignTokens.TOUCH_TARGET)
    .height(DesignTokens.TOUCH_TARGET)
    .backgroundColor(Color.Transparent)
    .accessibilityText(label)
    .enabled(!this.interactionSuppressed)
    .onClick(() => {
      if (!this.interactionSuppressed) {
        action();
      }
    })
  }

  @Builder
  private dashboardToolbar() {
    Row() {
      this.toolbarButton('◷', '查看历史记录', this.onOpenHistory)
      Blank()
      this.toolbarButton(
        this.bluetoothConnected ? '●' : 'ᛒ',
        `${this.bluetoothConnected ? '断开' : '连接'}蓝牙，${this.bluetoothStatus}`,
        this.onToggleBluetooth
      )
      this.toolbarButton('⚙', '设置', this.onOpenSettings)
    }
    .height(DesignTokens.TOOLBAR_HEIGHT)
    .width('100%')
    .constraintSize({ maxWidth: DesignTokens.CONTENT_MAX_WIDTH })
    .alignSelf(ItemAlign.Center)
    .padding({
      left: this.layoutWidth() * DesignTokens.PAGE_HORIZONTAL_RATIO,
      right: this.layoutWidth() * DesignTokens.PAGE_HORIZONTAL_RATIO
    })
  }

  @Builder
  private composer() {
    Row({ space: 10 }) {
      TextArea({
        placeholder: '和植物说点什么…',
        text: this.draft
      })
        .layoutWeight(1)
        .maxLines(5)
        .fontSize(16)
        .padding({ left: 18, right: 18, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.surface_translucent'))
        .borderRadius(DesignTokens.CORNER_INPUT)
        .border({
          width: 1,
          color: $r('app.color.separator')
        })
        .enabled(!this.interactionSuppressed)
        .onChange((value: string) => {
          this.draft = value;
        })

      Button() {
        Text('↑')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      }
      .width(48)
      .height(48)
      .borderRadius(24)
      .enabled(this.draft.trim().length > 0 && !this.interactionSuppressed)
      .opacity(
        this.draft.trim().length > 0 && !this.interactionSuppressed
          ? 1
          : 0.45
      )
      .backgroundColor(accentColorFor(this.appTheme))
      .onClick(() => this.submitDraft())
    }
    .width('100%')
  }

  @Builder
  private defaultArtwork() {
    Stack({ alignContent: Alignment.Center }) {
      Text('🌿')
        .fontSize(this.artworkWidth() * 0.28)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_secondary'))
  }

  @Builder
  private artworkImage() {
    if (this.artworkUri.length > 0) {
      Image(this.artworkUri)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
    } else {
      this.defaultArtwork()
    }
  }

  @Builder
  private generationMask() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor('#B84A4A4A')

      Circle()
        .width('74%')
        .aspectRatio(1)
        .fill(accentColorWithAlpha(this.appTheme, '70'))
        .opacity(0.42)

      Circle()
        .width('45%')
        .aspectRatio(1)
        .fill(Color.White)
        .opacity(0.18)

      Column({ space: 10 }) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color(Color.White)

        Text('正在生成 AI 图片')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)

        Button('取消')
          .height(36)
          .padding({ left: 18, right: 18 })
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('#52111111')
          .border({
            width: 1,
            color: '#70FFFFFF'
          })
          .enabled(!this.interactionSuppressed)
          .opacity(this.interactionSuppressed ? 0.5 : 1)
          .onClick(() => {
            if (!this.interactionSuppressed) {
              this.onCancelArtworkGeneration();
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .accessibilityText('正在生成 AI 图片，可以取消')
  }

  @Builder
  private editArtworkButton() {
    Button() {
      Text('✎')
        .fontSize(
          this.isCompactCoverScreen() && this.detailsExpanded ? 15 : 17
        )
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    }
    .width(this.artworkEditButtonSize())
    .height(this.artworkEditButtonSize())
    .borderRadius(this.artworkEditButtonSize() / 2)
    .backgroundColor($r('app.color.surface_translucent'))
    .border({
      width: 1,
      color: $r('app.color.separator')
    })
    .enabled(!this.interactionSuppressed)
    .opacity(this.interactionSuppressed ? 0.5 : 1)
    .accessibilityText(this.artworkUri.length > 0 ? '编辑植物图片' : '选择植物图片')
    .onClick(() => {
      if (!this.interactionSuppressed) {
        this.onEditArtwork();
      }
    })
  }

  @Builder
  private artwork() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack({ alignContent: Alignment.Center }) {
        this.artworkImage()
      }
      .width('100%')
      .height('100%')
      .accessibilityText(
        this.detailsExpanded ? '收起植物状态' : '查看植物状态'
      )
      .onClick(() => this.toggleDetails())
      .gesture(
        LongPressGesture({
          repeat: false,
          duration: 500
        })
          .onAction(() => {
            if (!this.isGeneratingArtwork && !this.interactionSuppressed) {
              this.onEditArtwork();
            }
          })
      )

      if (this.isGeneratingArtwork) {
        this.generationMask()
      } else {
        Row() {
          this.editArtworkButton()
        }
        .padding({
          top: this.artworkEditButtonInset(),
          right: this.artworkEditButtonInset()
        })
      }
    }
    .width(this.artworkWidth())
    .aspectRatio(0.75)
    .backgroundColor($r('app.color.background_secondary'))
    .borderRadius(this.artworkWidth() * 0.14)
    .clip(true)
    .border({
      width: 1.5,
      color: accentColorWithAlpha(this.appTheme, '80')
    })
  }

  @Builder
  private sensorGrid() {
    Column({ space: DesignTokens.GRID_SPACING }) {
      Row({ space: DesignTokens.GRID_SPACING }) {
        SensorMetricCard({ metric: this.temperatureMetric() })
          .layoutWeight(1)
        SensorMetricCard({ metric: this.humidityMetric() })
          .layoutWeight(1)
      }
      Row({ space: DesignTokens.GRID_SPACING }) {
        SensorMetricCard({ metric: this.soilMetric() })
          .layoutWeight(1)
        SensorMetricCard({ metric: this.lightMetric() })
          .layoutWeight(1)
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      this.dashboardToolbar()

      Scroll() {
        Column() {
          if (this.detailsExpanded) {
            this.composer()
            Blank().height(12)
          } else {
            Blank().height(
              this.isCompactCoverScreen()
                ? 8
                : this.contentHeight * 0.12
            )
          }

          this.artwork()

          if (this.detailsExpanded) {
            Blank().height(12)
            this.sensorGrid()
          }

          if (this.isCompactCoverScreen()) {
            Blank().height(10)
          } else {
            Blank().layoutWeight(1)
          }

          DiffuseOrbFallback({
            paused: this.motionPaused,
            normalizedLevel: this.voiceLevel,
            accentKind: this.accentKind,
            accentIntensity: this.accentIntensity,
            accentSequence: this.accentSequence
          })
            .width(this.orbWidth())
            .onClick(() => {
              if (!this.interactionSuppressed) {
                this.onOpenRealtime();
              }
            })

          Blank().height(16)
        }
        .width('100%')
        .constraintSize({
          minHeight: Math.max(0, this.contentHeight),
          maxWidth: DesignTokens.CONTENT_MAX_WIDTH
        })
        .alignSelf(ItemAlign.Center)
        .padding({
          left: this.layoutWidth() * DesignTokens.PAGE_HORIZONTAL_RATIO,
          right: this.layoutWidth() * DesignTokens.PAGE_HORIZONTAL_RATIO
        })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_primary'))
    .onAreaChange((_oldArea, newArea) => {
      const measuredWidth = Number.parseFloat(newArea.width.toString());
      const measuredHeight = Number.parseFloat(newArea.height.toString());
      if (measuredWidth > 0 && measuredHeight > DesignTokens.TOOLBAR_HEIGHT) {
        this.contentWidth = measuredWidth;
        this.contentHeight = measuredHeight - DesignTokens.TOOLBAR_HEIGHT;
      }
    })
  }
}
