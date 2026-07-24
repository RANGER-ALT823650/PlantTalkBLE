import { DesignTokens } from '../theme/DesignTokens';

export class SensorMetricViewModel {
  title: string;
  value: string;
  unit: string;
  symbol: string;
  tint: ResourceColor;

  constructor(
    title: string,
    value: string,
    unit: string,
    symbol: string,
    tint: ResourceColor
  ) {
    this.title = title;
    this.value = value;
    this.unit = unit;
    this.symbol = symbol;
    this.tint = tint;
  }
}

@Component
export struct SensorMetricCard {
  @Prop metric: SensorMetricViewModel;
  onTap: () => void = () => {};
  @State private pressed: boolean = false;

  build() {
    Column({ space: 10 }) {
      Row({ space: 7 }) {
        Text(this.metric.symbol)
          .fontSize(16)
        Text(this.metric.title)
          .fontSize(12)
          .fontColor(this.metric.tint)
        Blank()
        Text('›')
          .fontSize(16)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')

      Row({ space: 4 }) {
        Text(this.metric.value)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .fontFamily('monospace')
          .maxLines(1)
        if (this.metric.unit.length > 0) {
          Text(this.metric.unit)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.background_secondary'))
    .borderRadius(DesignTokens.CORNER_CARD)
    .border({
      width: this.pressed ? 1.5 : 1,
      color: this.metric.tint,
      style: BorderStyle.Solid
    })
    .opacity(this.pressed ? 0.85 : 1)
    .scale({ x: this.pressed ? 0.96 : 1, y: this.pressed ? 0.96 : 1 })
    .animation({ duration: 150, curve: Curve.EaseInOut })
    .onTouch((event) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(this.onTap)
  }
}
