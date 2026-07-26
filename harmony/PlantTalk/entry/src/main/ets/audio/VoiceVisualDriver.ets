/**
 * Audio sources are kept separate because the realtime model uses slightly
 * lower onset thresholds than the microphone path.
 */
export enum VoiceAudioSource {
  USER = 'user',
  ASSISTANT = 'assistant'
}

/**
 * `CONNECTION_ESTABLISHED` is intentionally not a mesh deformation. The orb
 * renders it as one whole-circle swell so connection success cannot be
 * mistaken for another spoken syllable.
 */
export enum VoiceVisualAccentKind {
  NONE = 'none',
  COLOR_SHIFT = 'colorShift',
  STRONG_PULSE = 'strongPulse',
  CONNECTION_ESTABLISHED = 'connectionEstablished'
}

export class VoiceVisualAccent {
  sequence: number;
  kind: VoiceVisualAccentKind;
  meshPointIndex: number;
  offsetX: number;
  offsetY: number;
  intensity: number;
  startedAtMs: number;

  constructor(
    sequence: number,
    kind: VoiceVisualAccentKind,
    meshPointIndex: number,
    offsetX: number,
    offsetY: number,
    intensity: number,
    startedAtMs: number
  ) {
    this.sequence = sequence;
    this.kind = kind;
    this.meshPointIndex = meshPointIndex;
    this.offsetX = offsetX;
    this.offsetY = offsetY;
    this.intensity = intensity;
    this.startedAtMs = startedAtMs;
  }

  deformsMesh(): boolean {
    return this.kind !== VoiceVisualAccentKind.CONNECTION_ESTABLISHED;
  }
}

class LevelEnvelope {
  fastDBFS: number | null = null;
  slowDBFS: number | null = null;
  lastAudibleAtMs: number | null = null;
}

export type VoiceVisualRandomUnit = () => number;

/**
 * Converts dense audio-meter frames into a quiet continuous level plus sparse
 * visual accents. The constants intentionally mirror the current iOS driver:
 *
 * - silence longer than 1.2 s rearms the strong-pulse burst budget;
 * - at most three strong pulses are allowed in any four-second window;
 * - strong/color accents have 650/350 ms cooldowns respectively;
 * - a connection pulse bypasses those cooldown checks, but arms both cooldowns
 *   so the first model syllable cannot stack another pulse on top of it.
 */
export class VoiceVisualDriver {
  normalizedLevel: number = 0;
  accent: VoiceVisualAccent | null = null;

  private userEnvelope: LevelEnvelope = new LevelEnvelope();
  private assistantEnvelope: LevelEnvelope = new LevelEnvelope();
  private lastColorShiftAtMs: number = -1_000_000_000_000;
  private lastStrongPulseAtMs: number = -1_000_000_000_000;
  private strongPulseTimesMs: number[] = [];
  private lastMeshPointIndex: number | null = null;
  private nextAccentSequence: number = 1;
  private randomUnit: VoiceVisualRandomUnit;

  constructor(randomUnit: VoiceVisualRandomUnit = (): number => Math.random()) {
    this.randomUnit = randomUnit;
  }

  ingest(
    source: VoiceAudioSource,
    levelDBFS: number,
    atMs: number = Date.now()
  ): void {
    const level = Math.min(-3, Math.max(-80, levelDBFS));
    const envelope = this.envelopeFor(source);

    if (envelope.fastDBFS === null || envelope.slowDBFS === null) {
      envelope.fastDBFS = level;
      envelope.slowDBFS = level;
      if (level > -48) {
        envelope.lastAudibleAtMs = atMs;
      }
      this.updateDisplayLevel(level);
      return;
    }

    const fast = envelope.fastDBFS * 0.55 + level * 0.45;
    const slow = envelope.slowDBFS * 0.93 + level * 0.07;
    envelope.fastDBFS = fast;
    envelope.slowDBFS = slow;

    if (envelope.lastAudibleAtMs !== null &&
      atMs - envelope.lastAudibleAtMs >= 1_200) {
      this.strongPulseTimesMs = [];
    }
    if (level > -48) {
      envelope.lastAudibleAtMs = atMs;
    }
    this.updateDisplayLevel(level);

    if (level <= -48) {
      return;
    }

    const onset = fast - slow;
    const strongThreshold =
      source === VoiceAudioSource.ASSISTANT ? 4.2 : 5.5;
    const colorShiftThreshold =
      source === VoiceAudioSource.ASSISTANT ? 2.0 : 2.8;
    this.strongPulseTimesMs = this.strongPulseTimesMs.filter(
      (timeMs: number): boolean => atMs - timeMs < 4_000
    );

    if (onset >= strongThreshold &&
      atMs - this.lastStrongPulseAtMs >= 650 &&
      this.strongPulseTimesMs.length < 3) {
      const intensity = this.clamp01((onset - strongThreshold) / 8);
      const probability = Math.min(0.82, 0.3 + intensity * 0.52);
      if (this.clampedRandomUnit() <= probability) {
        this.emitAccent(
          VoiceVisualAccentKind.STRONG_PULSE,
          intensity,
          atMs
        );
        this.lastStrongPulseAtMs = atMs;
        this.lastColorShiftAtMs = atMs;
        this.strongPulseTimesMs.push(atMs);
        return;
      }
    }

    if (onset >= colorShiftThreshold &&
      atMs - this.lastColorShiftAtMs >= 350) {
      const intensity = this.clamp01((onset - colorShiftThreshold) / 6);
      const probability = Math.min(0.72, 0.24 + intensity * 0.48);
      if (this.clampedRandomUnit() <= probability) {
        this.emitAccent(
          VoiceVisualAccentKind.COLOR_SHIFT,
          intensity,
          atMs
        );
        this.lastColorShiftAtMs = atMs;
      }
    }
  }

  /**
   * Emits connection success directly. It always produces a new `sequence`,
   * even when called during an audio accent, while normal audio accents are
   * cooled down from this exact timestamp.
   */
  emitConnectionEstablishedPulse(atMs: number = Date.now()): void {
    this.lastStrongPulseAtMs = atMs;
    this.lastColorShiftAtMs = atMs;
    this.accent = new VoiceVisualAccent(
      this.consumeSequence(),
      VoiceVisualAccentKind.CONNECTION_ESTABLISHED,
      5,
      0,
      0,
      1,
      atMs
    );
  }

  reset(): void {
    this.normalizedLevel = 0;
    this.accent = null;
    this.userEnvelope = new LevelEnvelope();
    this.assistantEnvelope = new LevelEnvelope();
    this.lastColorShiftAtMs = -1_000_000_000_000;
    this.lastStrongPulseAtMs = -1_000_000_000_000;
    this.strongPulseTimesMs = [];
    this.lastMeshPointIndex = null;
  }

  private envelopeFor(source: VoiceAudioSource): LevelEnvelope {
    return source === VoiceAudioSource.ASSISTANT
      ? this.assistantEnvelope
      : this.userEnvelope;
  }

  private updateDisplayLevel(levelDBFS: number): void {
    const target = this.clamp01((levelDBFS + 55) / 43);
    this.normalizedLevel = this.normalizedLevel * 0.78 + target * 0.22;
  }

  private emitAccent(
    kind: VoiceVisualAccentKind,
    intensity: number,
    atMs: number
  ): void {
    const internalPointIndices: number[] = [5, 6, 9, 10];
    let position = Math.min(
      internalPointIndices.length - 1,
      Math.floor(this.clampedRandomUnit() * internalPointIndices.length)
    );
    if (internalPointIndices[position] === this.lastMeshPointIndex) {
      position = (position + 1) % internalPointIndices.length;
    }
    const pointIndex = internalPointIndices[position];
    this.lastMeshPointIndex = pointIndex;

    const angle = this.clampedRandomUnit() * Math.PI * 2;
    const baseAmplitude =
      kind === VoiceVisualAccentKind.STRONG_PULSE ? 0.06 : 0.03;
    const amplitudeRange =
      kind === VoiceVisualAccentKind.STRONG_PULSE ? 0.035 : 0.02;
    const amplitude = baseAmplitude + amplitudeRange * intensity;

    this.accent = new VoiceVisualAccent(
      this.consumeSequence(),
      kind,
      pointIndex,
      Math.cos(angle) * amplitude,
      Math.sin(angle) * amplitude,
      intensity,
      atMs
    );
  }

  private consumeSequence(): number {
    const sequence = this.nextAccentSequence;
    this.nextAccentSequence += 1;
    return sequence;
  }

  private clampedRandomUnit(): number {
    return this.clamp01(this.randomUnit());
  }

  private clamp01(value: number): number {
    return Math.min(1, Math.max(0, value));
  }
}
