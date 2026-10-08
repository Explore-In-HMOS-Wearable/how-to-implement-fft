/*
 * dsp/Spectrum.ets — complex FFT output to a magnitude spectrum you can read.
 *
 * THIS FILE IMPORTS NOTHING. See dsp/Fft.ets for why.
 *
 * Two things here are easy to get wrong and both make the numbers meaningless rather than
 * merely ugly:
 *
 *   1. Scaling. A bar chart of raw |X[k]| is a picture, not a measurement. The scaling
 *      below is amplitude-correct, so a full-scale sine reads 0 dBFS at any N and under
 *      any window.
 *
 *   2. Peak location. The peak bin is not the peak frequency. At N = 4096 and 44.1 kHz
 *      the bins are 10.77 Hz apart — about a semitone at guitar pitch. Parabolic
 *      interpolation recovers the true peak to a fraction of a hertz.
 */

/** Anything quieter than this reads as silence. Keeps log10(0) out of the display. */
export const DB_FLOOR: number = -120;

export interface PeakEstimate {
  /** Index of the largest bin. -1 when the spectrum is empty or entirely below the floor. */
  binIndex: number;
  /** Frequency of that bin's centre, in Hz — the uninterpolated answer. */
  binHz: number;
  /** Parabolically interpolated frequency, in Hz. This is the one to display. */
  frequencyHz: number;
  /** Interpolated amplitude in dBFS, where a full-scale sine is 0. */
  magnitudeDb: number;
  /** Sub-bin offset applied, in bins, within [-0.5, +0.5]. */
  binOffset: number;
}

export class Spectrum {
  /** Transform length the spectrum was computed from. */
  readonly fftSize: number;
  /** Number of usable bins: N/2 + 1, DC through Nyquist inclusive. */
  readonly binCount: number;

  /** Linear magnitude |X[k]|, unscaled. */
  readonly magnitude: Float64Array;
  /** Amplitude-corrected dBFS, floored at DB_FLOOR. This is what the UI plots. */
  readonly decibels: Float64Array;

  constructor(fftSize: number) {
    this.fftSize = fftSize;
    this.binCount = (fftSize >> 1) + 1;
    this.magnitude = new Float64Array(this.binCount);
    this.decibels = new Float64Array(this.binCount);
    this.decibels.fill(DB_FLOOR);
  }

  /**
   * Fill `magnitude` and `decibels` from a complex spectrum.
   *
   * Only bins 0..N/2 are computed. For a real input the spectrum is conjugate-symmetric —
   * X[N-k] is the complex conjugate of X[k] — so the upper half carries no new
   * information and plotting it just mirrors the picture.
   *
   * `coherentGain` comes from the WindowFunction that was applied to the frame; pass 1.0
   * if no window was used.
   */
  compute(re: Float64Array, im: Float64Array, coherentGain: number): void {
    const n: number = this.fftSize;
    const count: number = this.binCount;
    const mag = this.magnitude;
    const db = this.decibels;

    // A real sine of amplitude A at a bin centre produces a bin magnitude of A times N times CG, halved, so
    // recovering A means doubling and dividing by (N * CG). DC and Nyquist are not part
    // of a conjugate pair, so they get no doubling.
    const gain: number = 2 / (n * coherentGain);
    const edgeGain: number = 1 / (n * coherentGain);
    const nyquist: number = count - 1;

    for (let k: number = 0; k < count; k++) {
      const r: number = re[k];
      const i: number = im[k];
      const m: number = Math.sqrt(r * r + i * i);
      mag[k] = m;

      const amplitude: number = m * ((k === 0 || k === nyquist) ? edgeGain : gain);
      db[k] = amplitude > 0 ? Math.max(DB_FLOOR, 20 * Math.log10(amplitude)) : DB_FLOOR;
    }
  }

  /** Centre frequency of bin `k`, in Hz. */
  binToHz(bin: number, sampleRate: number): number {
    return bin * sampleRate / this.fftSize;
  }

  /** Bin spacing in Hz — the raw resolution limit before interpolation. */
  binWidthHz(sampleRate: number): number {
    return sampleRate / this.fftSize;
  }

  /**
   * Largest peak between `minHz` and `maxHz`, refined by parabolic interpolation.
   *
   * The interpolation fits a parabola through the dB values of the peak bin and its two
   * neighbours and takes its vertex. dB rather than linear magnitude because a windowed
   * main lobe is close to parabolic on a log scale, which is what makes three points
   * enough.
   *
   * DC and Nyquist are excluded from the search: neither has two neighbours, and DC is
   * usually just the microphone's offset anyway.
   */
  findPeak(sampleRate: number, minHz: number, maxHz: number): PeakEstimate {
    const db = this.decibels;
    const count: number = this.binCount;

    let lo: number = Math.max(1, Math.ceil(minHz * this.fftSize / sampleRate));
    let hi: number = Math.min(count - 2, Math.floor(maxHz * this.fftSize / sampleRate));

    let peak: number = -1;
    let peakDb: number = DB_FLOOR;
    for (let k: number = lo; k <= hi; k++) {
      if (db[k] > peakDb) {
        peakDb = db[k];
        peak = k;
      }
    }

    if (peak < 0 || peakDb <= DB_FLOOR) {
      const empty: PeakEstimate = {
        binIndex: -1, binHz: 0, frequencyHz: 0, magnitudeDb: DB_FLOOR, binOffset: 0
      };
      return empty;
    }

    const yLeft: number = db[peak - 1];
    const yMid: number = db[peak];
    const yRight: number = db[peak + 1];

    // Vertex of the parabola through (-1, yLeft), (0, yMid), (+1, yRight).
    let offset: number = 0;
    const denom: number = yLeft - 2 * yMid + yRight;
    if (denom !== 0) {
      offset = 0.5 * (yLeft - yRight) / denom;
      // A true peak's vertex lies within half a bin. Anything further means the three
      // points weren't a main lobe (noise, or a lobe clipped by the search range), so
      // fall back to the bin centre rather than reporting a wild frequency.
      if (offset < -0.5 || offset > 0.5 || Number.isNaN(offset)) {
        offset = 0;
      }
    }

    const interpolatedDb: number = yMid - 0.25 * (yLeft - yRight) * offset;
    const result: PeakEstimate = {
      binIndex: peak,
      binHz: this.binToHz(peak, sampleRate),
      frequencyHz: this.binToHz(peak + offset, sampleRate),
      magnitudeDb: interpolatedDb,
      binOffset: offset
    };
    return result;
  }
}
