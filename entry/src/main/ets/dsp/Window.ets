/*
 * dsp/Window.ets — analysis windows for the FFT.
 *
 * THIS FILE IMPORTS NOTHING. See dsp/Fft.ets for why.
 *
 * An FFT assumes its input frame repeats forever. A sine whose period doesn't divide the
 * frame length evenly therefore has a discontinuity at the frame boundary, and that
 * discontinuity smears energy across every bin — spectral leakage. A window tapers the
 * frame to zero at both ends so the wrap-around is smooth.
 *
 * Nothing is free: tapering widens the main lobe, so leakage is traded against resolution.
 * Switching windows live on the Controls page makes that trade visible.
 */

export enum WindowType {
  RECTANGULAR = 0,   // no window at all — narrowest main lobe, worst leakage
  HANN = 1,          // the sensible default for audio
  HAMMING = 2,       // lower first sidelobe than Hann, higher far sidelobes
  BLACKMAN = 3       // widest main lobe, lowest leakage
}

export const WINDOW_TYPES: WindowType[] = [
  WindowType.RECTANGULAR,
  WindowType.HANN,
  WindowType.HAMMING,
  WindowType.BLACKMAN
];

export function windowTypeName(type: WindowType): string {
  switch (type) {
    case WindowType.RECTANGULAR: return 'Rect';
    case WindowType.HANN: return 'Hann';
    case WindowType.HAMMING: return 'Hamming';
    case WindowType.BLACKMAN: return 'Blackman';
    default: return 'Unknown';
  }
}

export class WindowFunction {
  readonly type: WindowType;
  readonly size: number;

  /** The window itself, precomputed once. Never recomputed per frame. */
  readonly coefficients: Float64Array;

  /**
   * Coherent gain: the mean of the coefficients.
   *
   * Applying a window scales every amplitude down. Dividing by this puts amplitudes back
   * on a scale where a full-scale sine reads 0 dBFS instead of some window-dependent
   * number. Without it the displayed dB values are arbitrary. Hann is 0.5, Hamming 0.54,
   * Blackman 0.42, Rectangular 1.0 — computed from the array rather than hard-coded, so
   * adding a window type can't silently break the scaling.
   */
  readonly coherentGain: number;

  /** RMS of the coefficients — the equivalent correction for broadband noise levels. */
  readonly noiseGain: number;

  constructor(type: WindowType, size: number) {
    if (size < 2) {
      throw new Error(`WindowFunction: size must be >= 2, got ${size}`);
    }

    this.type = type;
    this.size = size;

    const w = new Float64Array(size);
    // Periodic (divide by N, not N-1) — the correct form for spectral analysis, as
    // opposed to the symmetric form used for FIR filter design.
    const step: number = 6.283185307179586 / size;

    for (let n: number = 0; n < size; n++) {
      const x: number = step * n;
      switch (type) {
        case WindowType.HANN:
          w[n] = 0.5 - 0.5 * Math.cos(x);
          break;
        case WindowType.HAMMING:
          w[n] = 0.54 - 0.46 * Math.cos(x);
          break;
        case WindowType.BLACKMAN:
          w[n] = 0.42 - 0.5 * Math.cos(x) + 0.08 * Math.cos(2 * x);
          break;
        case WindowType.RECTANGULAR:
        default:
          w[n] = 1;
          break;
      }
    }

    let sum: number = 0;
    let sumSq: number = 0;
    for (let n: number = 0; n < size; n++) {
      sum += w[n];
      sumSq += w[n] * w[n];
    }

    this.coefficients = w;
    this.coherentGain = sum / size;
    this.noiseGain = Math.sqrt(sumSq / size);
  }

  /**
   * Multiply `src` by the window into `dst`. Both must be at least `size` long.
   * `dst` may be the same array as `src` for an in-place taper.
   */
  apply(src: Float64Array, dst: Float64Array): void {
    const n: number = this.size;
    if (src.length < n || dst.length < n) {
      throw new Error(
        `WindowFunction.apply: buffers must be >= ${n}, got src=${src.length} dst=${dst.length}`
      );
    }
    const w = this.coefficients;
    for (let i: number = 0; i < n; i++) {
      dst[i] = src[i] * w[i];
    }
  }
}
