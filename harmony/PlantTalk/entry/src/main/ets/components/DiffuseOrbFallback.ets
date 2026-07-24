import { accentColorFor, accentColorWithAlpha } from '../theme/AppTheme';

/**
 * Stage-one fallback for the iOS MeshGradient orb.
 *
 * The final P0 implementation will replace only this component with an
 * XComponent/GLSL bicubic mesh. Keeping the public surface small prevents that
 * renderer change from invalidating HomeDashboard.
 */
@Component
export struct DiffuseOrbFallback {
  @StorageLink('appTheme') appTheme: string = 'blue';
  @StorageLink('reduceMotion') reduceMotion: boolean = false;
  @Prop paused: boolean = false;
  @Prop normalizedLevel: number = 0;
  @State private breathScale: number = 1;

  private visualScale(): number {
    if (this.reduceMotion || this.paused) {
      return 1;
    }
    return this.breathScale *
      (1 + Math.max(0, Math.min(1, this.normalizedLevel)) * 0.012);
  }

  aboutToAppear(): void {
    if (this.reduceMotion || this.paused) {
      return;
    }
    this.getUIContext().animateTo({
      duration: 1800,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.breathScale = 1.018;
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width('100%')
        .height('100%')
        .fill(accentColorFor(this.appTheme))

      Circle()
        .width('72%')
        .height('72%')
        .fill('#36FFFFFF')
        .translate({ x: -12, y: -10 })

      Circle()
        .width('42%')
        .height('42%')
        .fill('#5CFFFFFF')
        .translate({ x: 18, y: 20 })

      Circle()
        .width('100%')
        .height('100%')
        .fill('#00000000')
        .stroke('#47FFFFFF')
        .strokeWidth(1)
    }
    .width('100%')
    .aspectRatio(1)
    .scale({
      x: this.visualScale(),
      y: this.visualScale()
    })
    .shadow({
      radius: 24,
      color: accentColorWithAlpha(this.appTheme, '40'),
      offsetY: 10
    })
  }
}
