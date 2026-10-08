/*
 * audio/SignalGenerator.ets — synthetic test signals.
 *
 * This is the default source on launch, and that is a deliberate choice rather than a
 * fallback. Three reasons:
 *
 *   1. You know the answer before you look. A 440 Hz sine had better produce a peak at
 *      440 Hz; if it doesn't, the bug is in the code and not in the room's acoustics.
 *   2. It works on the DevEco simulator, which has no microphone.
 *   3. No permission dialog stands between opening the app and seeing a spectrum.
 *
 * Phase is carried across calls, so consecutive frames are continuous. Restarting the
 * phase at every buffer would inject a discontinuity at each boundary — which is exactly
 * the spectral leakage the windowing section is about, and would be indistinguishable
 * from a real artefact.
 */

import { SignalKind } from '../common/types';

const TWO_PI: number = 6.283185307179586;

/** Harmonic amplitudes for the HARMONIC waveform — a plucked-string-ish 1/n rolloff. */
const HARMONIC_GAINS: number[] = [1.0, 0.5, 0.33, 0.25, 0.2];

export class SignalGenerator {
  private kind: SignalKind = SignalKind.SINE;
  private sampleRate: number;
  private frequencyHz: number = 440;
  private amplitude: number = 0.5;

  /** Running phase in radians, wrapped to [0, 2*pi). */
  private phase: number = 0;
  /** Chirp sweep position, 0..1, advancing once per sample. */
  private sweep: number = 0;
  /** Deterministic noise state, so "white noise" is reproducible run to run. */
  private rngState: number = 0x9E3779B9;

  constructor(sampleRate: number) {
    this.sampleRate = sampleRate;
  }

  setKind(kind: SignalKind): void {
    this.kind = kind;
    this.sweep = 0;
  }

  setFrequency(hz: number): void {
    this.frequencyHz = hz;
  }

  setSampleRate(rate: number): void {
    this.sampleRate = rate;
  }

  getKind(): SignalKind {
    return this.kind;
  }

  getFrequency(): number {
    return this.frequencyHz;
  }

  /**
   * Describes what the spectrum SHOULD look like, for display next to the live reading.
   * Being able to compare "expected" against "measured" on screen is most of why the
   * synthetic source is worth having.
   */
  expectedPeakHz(): number {
    switch (this.kind) {
      case SignalKind.SINE:
      case SignalKind.TWO_TONE:
      case SignalKind.HARMONIC:
        return this.frequencyHz;
      default:
        return 0;   // chirp sweeps, noise has no peak
    }
  }

  /** Fill `dst[0..count)` with the next block of samples. Allocates nothing. */
  fill(dst: Float64Array, count: number): void {
    const n: number = Math.min(count, dst.length);
    const step: number = TWO_PI * this.frequencyHz / this.sampleRate;

    switch (this.kind) {
      case SignalKind.SINE:
        for (let i: number = 0; i < n; i++) {
          dst[i] = this.amplitude * Math.sin(this.phase);
          this.advance(step);
        }
        break;

      case SignalKind.TWO_TONE: {
        // A perfect fifth up (3:2). Two clearly separated peaks, far enough apart to
        // resolve at any supported N.
        const a: number = this.amplitude * 0.6;
        for (let i: number = 0; i < n; i++) {
          dst[i] = a * (Math.sin(this.phase) + Math.sin(this.phase * 1.5));
          this.advance(step);
        }
        break;
      }

      case SignalKind.HARMONIC: {
        // Fundamental plus four harmonics — what a real instrument note looks like, and
        // the case where an FFT genuinely beats a single-pitch estimator.
        for (let i: number = 0; i < n; i++) {
          let sum: number = 0;
          for (let h: number = 0; h < HARMONIC_GAINS.length; h++) {
            sum += HARMONIC_GAINS[h] * Math.sin(this.phase * (h + 1));
          }
          dst[i] = this.amplitude * 0.45 * sum;
          this.advance(step);
        }
        break;
      }

      case SignalKind.CHIRP: {
        // Linear sweep, 80 Hz to 4 kHz over two seconds, then repeat. Makes the peak
        // tracker visibly follow something.
        const lowHz: number = 80;
        const highHz: number = 4000;
        const sweepSamples: number = this.sampleRate * 2;
        for (let i: number = 0; i < n; i++) {
          const hz: number = lowHz + (highHz - lowHz) * this.sweep;
          dst[i] = this.amplitude * Math.sin(this.phase);
          this.advance(TWO_PI * hz / this.sampleRate);
          this.sweep += 1 / sweepSamples;
          if (this.sweep >= 1) {
            this.sweep = 0;
          }
        }
        break;
      }

      case SignalKind.NOISE:
      default:
        for (let i: number = 0; i < n; i++) {
          dst[i] = this.amplitude * this.nextNoise();
        }
        break;
    }
  }

  private advance(step: number): void {
    this.phase += step;
    if (this.phase >= TWO_PI) {
      this.phase -= TWO_PI;
    }
  }

  /** Uniform in [-1, 1) from a linear congruential generator. */
  private nextNoise(): number {
    this.rngState = (Math.imul(this.rngState, 1664525) + 1013904223) >>> 0;
    return (this.rngState / 2147483648) - 1;
  }
}
