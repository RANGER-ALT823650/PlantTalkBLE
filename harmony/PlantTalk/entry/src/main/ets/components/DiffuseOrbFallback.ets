import { VoiceVisualAccentKind } from '../audio/VoiceVisualDriver';
import { accentColorFor, accentColorWithAlpha } from '../theme/AppTheme';

/**
 * Activity values intentionally match the current iOS state mapping.
 */
export class OrbActivity {
  static readonly IDLE: number = 1.34;
  static readonly CONNECTING: number = 1.62;
  static readonly CONNECTED: number = 2.5;
}

/**
 * The current iOS 4x4 mesh tint-to-white mix. This fallback samples the same
 * field for its translucent layers; a future XComponent mesh renderer can use
 * the exported values without changing the component's public input surface.
 */
export const ORB_SOFTENING: number[] = [
  0.12, 0.18, 0.3, 0.22,
  0.25, 0.18, 0.36, 0.32,
  0.78, 0.52, 0.78, 0.76,
  0.9, 0.94, 1, 0.92
];

export function orbAccentPulseAmplitude(
  kind: VoiceVisualAccentKind,
  intensity: number
): number {
  const clampedIntensity = Math.min(1, Math.max(0, intensity));
  if (kind === VoiceVisualAccentKind.STRONG_PULSE) {
    return 0.055 + 0.04 * clampedIntensity;
  }
  if (kind === VoiceVisualAccentKind.CONNECTION_ESTABLISHED) {
    return 0.16;
  }
  return 0;
}

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
  @Prop activity: number = OrbActivity.IDLE;
  @Prop normalizedLevel: number = 0;
  @Prop accentKind: VoiceVisualAccentKind = VoiceVisualAccentKind.NONE;
  @Prop accentIntensity: number = 0;
  @Watch('handleAccentSequenceChanged')
  @Prop accentSequence: number = 0;
  @State private breathScale: number = 1;
  @State private driftPhase: number = -1;
  @State private pulseEnvelope: number = 0;
  @State private localAccentEnvelope: number = 0;

  private clamp01(value: number): number {
    return Math.min(1, Math.max(0, value));
  }

  private visualScale(): number {
    if (this.reduceMotion || this.paused) {
      return 1;
    }
    const breathing = this.clamp01(this.normalizedLevel) * 0.012;
    const pulse = this.pulseEnvelope * orbAccentPulseAmplitude(
      this.accentKind,
      this.accentIntensity
    );
    return this.breathScale * (1 + breathing + pulse);
  }

  private motionDuration(): number {
    const activity = Math.max(0, this.activity);
    const idlePhaseSpeed = 0.34 + 0.28 * OrbActivity.IDLE;
    const phaseSpeed = Math.max(0.1, 0.34 + 0.28 * activity);
    return Math.round(1_800 * idlePhaseSpeed / phaseSpeed);
  }

  private localAccentOpacity(): number {
    if (this.accentKind === VoiceVisualAccentKind.CONNECTION_ESTABLISHED) {
      return 0;
    }
    return this.localAccentEnvelope * (0.12 + this.clamp01(this.accentIntensity) * 0.18);
  }

  private handleAccentSequenceChanged(): void {
    if (this.reduceMotion || this.paused ||
      this.accentKind === VoiceVisualAccentKind.NONE) {
      this.pulseEnvelope = 0;
      this.localAccentEnvelope = 0;
      return;
    }

    const sequence = this.accentSequence;
    const attackDuration =
      this.accentKind === VoiceVisualAccentKind.CONNECTION_ESTABLISHED
        ? 110
        : this.accentKind === VoiceVisualAccentKind.STRONG_PULSE
        ? 90
        : 70;
    const releaseDuration =
      this.accentKind === VoiceVisualAccentKind.CONNECTION_ESTABLISHED
        ? 300
        : this.accentKind === VoiceVisualAccentKind.STRONG_PULSE
        ? 500
        : 340;

    this.pulseEnvelope = 0;
    this.localAccentEnvelope = 0;
    this.getUIContext().animateTo({
      duration: attackDuration,
      curve: Curve.EaseOut,
      onFinish: () => {
        if (sequence !== this.accentSequence) {
          return;
        }
        this.getUIContext().animateTo({
          duration: releaseDuration,
          curve: Curve.EaseIn,
          onFinish: () => {
            if (sequence === this.accentSequence) {
              this.pulseEnvelope = 0;
              this.localAccentEnvelope = 0;
            }
          }
        }, () => {
          this.pulseEnvelope = 0;
          this.localAccentEnvelope = 0;
        });
      }
    }, () => {
      this.pulseEnvelope = 1;
      this.localAccentEnvelope =
        this.accentKind === VoiceVisualAccentKind.CONNECTION_ESTABLISHED ? 0 : 1;
    });
  }

  aboutToAppear(): void {
    if (this.reduceMotion || this.paused) {
      return;
    }
    this.getUIContext().animateTo({
      duration: this.motionDuration(),
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.breathScale = 1.018;
      this.driftPhase = 1;
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
        .fill(Color.White)
        .opacity(Math.min(1, ORB_SOFTENING[5] + this.localAccentOpacity()))
        .translate({
          x: -12 + this.driftPhase * (3 + this.activity * 1.4),
          y: -10 - this.driftPhase * (2 + this.activity)
        })

      Circle()
        .width('42%')
        .height('42%')
        .fill(Color.White)
        .opacity(ORB_SOFTENING[10])
        .translate({
          x: 18 - this.driftPhase * (2 + this.activity),
          y: 20 + this.driftPhase * (2 + this.activity * 1.2)
        })

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
