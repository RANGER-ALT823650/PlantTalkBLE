import curves from '@ohos.curves';
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
  @Prop interactionSuppressed: boolean = false;
  @Prop motionPaused: boolean = false;
  onOpenHistory: () => void = () => {};
  onToggleBluetooth: () => void = () => {};
  onOpenSettings: () => void = () => {};
  onSendText: (message: string) => void = () => {};
  onOpenRealtime: () => void = () => {};

  @State private detailsExpanded: boolean = false;
  @State private draft: string = '';
  @State private contentWidth: number = 360;
  @State private contentHeight: number = 700;

  private layoutWidth(): number {
    return Math.min(this.contentWidth, DesignTokens.CONTENT_MAX_WIDTH);
  }

  private artworkWidth(): number {
    const usableWidth = this.layoutWidth() * (1 - DesignTokens.PAGE_HORIZONTAL_RATIO * 2);
    const widthDriven = usableWidth * (
      this.detailsExpanded
        ? DesignTokens.ARTWORK_EXPANDED_RATIO
        : DesignTokens.ARTWORK_COLLAPSED_RATIO
    );
    const heightDriven = this.contentHeight * (this.detailsExpanded ? 0.25 : 0.42);
    return Math.min(widthDriven, heightDriven);
  }

  private orbWidth(): number {
    const usableWidth = this.layoutWidth() * (1 - DesignTokens.PAGE_HORIZONTAL_RATIO * 2);
    return Math.min(
      usableWidth * DesignTokens.ORB_WIDTH_RATIO,
      this.contentHeight * 0.22
    );
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
    if (this.interactionSuppressed) {
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
  private toolbar() {
    Row() {
      this.toolbarButton('◷', '查看历史记录', this.onOpenHistory)
      Blank()
      this.toolbarButton('ᛒ', '连接蓝牙', this.onToggleBluetooth)
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
  private artwork() {
    Stack({ alignContent: Alignment.Center }) {
      Text('🌿')
        .fontSize(this.artworkWidth() * 0.28)
    }
    .width(this.artworkWidth())
    .aspectRatio(0.75)
    .backgroundColor($r('app.color.background_secondary'))
    .borderRadius(this.artworkWidth() * 0.14)
    .border({
      width: 1.5,
      color: accentColorWithAlpha(this.appTheme, '80')
    })
    .onClick(() => this.toggleDetails())
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
      this.toolbar()

      Scroll() {
        Column() {
          if (this.detailsExpanded) {
            this.composer()
            Blank().height(12)
          } else {
            Blank().height(this.contentHeight * 0.12)
          }

          this.artwork()

          if (this.detailsExpanded) {
            Blank().height(12)
            this.sensorGrid()
          }

          Blank().layoutWeight(1)

          DiffuseOrbFallback({
            paused: this.motionPaused,
            normalizedLevel: 0
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
        .height(Math.max(this.contentHeight, this.detailsExpanded ? 760 : 540))
        .constraintSize({ maxWidth: DesignTokens.CONTENT_MAX_WIDTH })
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
      this.contentWidth = Number.parseFloat(newArea.width.toString());
      this.contentHeight = Number.parseFloat(newArea.height.toString()) - DesignTokens.TOOLBAR_HEIGHT;
    })
  }
}
