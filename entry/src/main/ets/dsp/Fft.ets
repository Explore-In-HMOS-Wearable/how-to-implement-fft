/*
 * dsp/Fft.ets — Cooley-Tukey radix-2 FFT in pure ArkTS.
 *
 * THIS FILE IMPORTS NOTHING. No @kit.*, no @ohos.*, no ArkUI, not even another file in
 * this project. Only ArkTS built-ins (Math, Float64Array, Uint16Array). Copy it into any
 * ArkTS project and it works unchanged — that is the point of this codelab.
 *
 * Algorithm: iterative, in-place, decimation-in-time (DIT) radix-2.
 *
 *   forward:  X[k] = sum over n of  x[n] * e^(-2*pi*i*k*n/N)
 *   inverse:  x[n] = (1/N) * sum over k of  X[k] * e^(+2*pi*i*k*n/N)
 *
 * Real and imaginary parts live in two separate Float64Arrays rather than one interleaved
 * array. Interleaving saves nothing here and fills the inner loop with `*2` / `+1` index
 * arithmetic that obscures the butterfly.
 */

const TWO_PI: number = 6.283185307179586;

/** Largest transform this implementation accepts (bounded by Uint16Array in revTable). */
export const MAX_FFT_SIZE: number = 65536;

/** Frame sizes the app offers. 4096 is the default the ticket calls for. */
export const SUPPORTED_SIZES: number[] = [256, 512, 1024, 2048, 4096];

export function isPowerOfTwo(n: number): boolean {
  return n >= 2 && (n & (n - 1)) === 0;
}

/** log2 of a power of two, without touching Math.log2 (exact, integer-only). */
export function log2Exact(n: number): number {
  let levels: number = 0;
  while ((1 << levels) < n) {
    levels++;
  }
  return levels;
}

export class Fft {
  /** Transform length N. Always a power of two. */
  readonly size: number;
  /** Number of butterfly stages: log2(N). 12 at N = 4096. */
  readonly levels: number;

  /*
   * Everything expensive is computed ONCE, here, and never inside transform().
   *
   * The naive version of this algorithm calls Math.cos and Math.sin inside the butterfly
   * loop — roughly 24,576 transcendental calls per 4096-point frame. Hoisting them into a
   * table turns the inner loop into pure multiply-add. Compare against NaiveFft below to
   * see the difference on your own hardware.
   */
  private readonly revTable: Uint16Array;   //     N entries — bit-reversal permutation
  private readonly cosTable: Float64Array;  // N/2 entries — cos(2*pi*k/N)
  private readonly sinTable: Float64Array;  // N/2 entries — sin(2*pi*k/N)

  constructor(size: number) {
    if (!isPowerOfTwo(size)) {
      throw new Error(`Fft: size must be a power of two, got ${size}`);
    }
    if (size > MAX_FFT_SIZE) {
      throw new Error(`Fft: size must be <= ${MAX_FFT_SIZE}, got ${size}`);
    }

    this.size = size;
    this.levels = log2Exact(size);

    // --- bit-reversal permutation table ---------------------------------------------
    // rev[i] is i with its `levels` bits reversed. Built incrementally: the reversal of i
    // is the reversal of (i >> 1) shifted down one place, with i's low bit moved to the top.
    const rev = new Uint16Array(size);
    const topBit: number = this.levels - 1;
    for (let i: number = 1; i < size; i++) {
      rev[i] = (rev[i >> 1] >> 1) | ((i & 1) << topBit);
    }
    this.revTable = rev;

    // --- twiddle factor tables ------------------------------------------------------
    // Only N/2 distinct angles are ever needed: stage `len` strides the table by N/len.
    const half: number = size >> 1;
    const cos = new Float64Array(half);
    const sin = new Float64Array(half);
    for (let k: number = 0; k < half; k++) {
      const angle: number = TWO_PI * k / size;
      cos[k] = Math.cos(angle);
      sin[k] = Math.sin(angle);
    }
    this.cosTable = cos;
    this.sinTable = sin;
  }

  /**
   * Forward transform, in place. `re` and `im` must both be exactly `size` long.
   * On return they hold the complex spectrum X[0..N-1].
   */
  forward(re: Float64Array, im: Float64Array): void {
    this.checkBuffers(re, im);
    this.run(re, im, -1);
  }

  /**
   * Inverse transform, in place, including the 1/N scaling.
   *
   * The only difference from the forward direction is the sign of the imaginary part of
   * the twiddle factor, plus the final scale. That is the whole trick — no second
   * algorithm, no second set of tables.
   */
  inverse(re: Float64Array, im: Float64Array): void {
    this.checkBuffers(re, im);
    this.run(re, im, 1);

    const n: number = this.size;
    const scale: number = 1 / n;
    for (let i: number = 0; i < n; i++) {
      re[i] *= scale;
      im[i] *= scale;
    }
  }

  /**
   * Convenience wrapper for the common case: N real samples in, complex spectrum out.
   * Copies `samples` into `re` and zeroes `im`, then runs the forward transform.
   *
   * `re` and `im` are caller-owned scratch buffers, reused across frames. Nothing is
   * allocated here — in the steady-state audio path that matters more than raw throughput,
   * because GC pauses are what make a live spectrum display stutter.
   */
  forwardReal(samples: Float64Array, re: Float64Array, im: Float64Array): void {
    const n: number = this.size;
    if (samples.length < n) {
      throw new Error(`Fft.forwardReal: need ${n} samples, got ${samples.length}`);
    }
    for (let i: number = 0; i < n; i++) {
      re[i] = samples[i];
      im[i] = 0;
    }
    this.forward(re, im);
  }

  private checkBuffers(re: Float64Array, im: Float64Array): void {
    if (re.length !== this.size || im.length !== this.size) {
      throw new Error(
        `Fft: buffers must be length ${this.size}, got re=${re.length} im=${im.length}`
      );
    }
  }

  /**
   * The transform itself. `sign` is -1 for forward, +1 for inverse.
   *
   * Step 1 reorders the input so that step 2's butterflies can read adjacent memory.
   * Step 2 then combines size-1 transforms into size-2, size-2 into size-4, and so on —
   * log2(N) stages, N/2 butterflies each, which is where the N log N comes from.
   */
  private run(re: Float64Array, im: Float64Array, sign: number): void {
    const n: number = this.size;
    const rev = this.revTable;
    const cosTable = this.cosTable;
    const sinTable = this.sinTable;

    // --- 1. bit-reversal permutation ------------------------------------------------
    // Swapping only when rev[i] > i visits each pair exactly once. Without that guard
    // every pair is swapped twice and the array comes back unchanged.
    for (let i: number = 0; i < n; i++) {
      const j: number = rev[i];
      if (j > i) {
        const tr: number = re[i];
        re[i] = re[j];
        re[j] = tr;
        const ti: number = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }

    // --- 2. log2(N) butterfly stages ------------------------------------------------
    for (let len: number = 2; len <= n; len <<= 1) {
      const half: number = len >> 1;
      const step: number = n / len;   // stride into the N/2-entry twiddle table

      for (let i: number = 0; i < n; i += len) {
        for (let j: number = 0, k: number = 0; j < half; j++, k += step) {
          const wr: number = cosTable[k];
          const wi: number = sign * sinTable[k];

          const a: number = i + j;
          const b: number = a + half;

          // Twiddle product: multiply the lower input by the twiddle factor (complex multiply).
          const rb: number = re[b];
          const ib: number = im[b];
          const tr: number = rb * wr - ib * wi;
          const ti: number = rb * wi + ib * wr;

          // Butterfly: the lower output is the difference, the upper output is the sum.
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] = re[a] + tr;
          im[a] = im[a] + ti;
        }
      }
    }
  }
}

/**
 * The same algorithm with the twiddle tables removed — Math.cos and Math.sin are called
 * inside the butterfly instead.
 *
 * This exists ONLY as the measured baseline for the README's "why precompute?" section.
 * Never use it in the audio path. At N = 4096 it performs 24,576 transcendental calls per
 * frame where Fft performs zero; the Diagnostics page reports both.
 */
export class NaiveFft {
  readonly size: number;

  constructor(size: number) {
    if (!isPowerOfTwo(size)) {
      throw new Error(`NaiveFft: size must be a power of two, got ${size}`);
    }
    this.size = size;
  }

  forward(re: Float64Array, im: Float64Array): void {
    const n: number = this.size;
    const levels: number = log2Exact(n);

    for (let i: number = 0; i < n; i++) {
      let j: number = 0;
      for (let bit: number = 0; bit < levels; bit++) {
        j = (j << 1) | ((i >> bit) & 1);
      }
      if (j > i) {
        const tr: number = re[i];
        re[i] = re[j];
        re[j] = tr;
        const ti: number = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }

    for (let len: number = 2; len <= n; len <<= 1) {
      const half: number = len >> 1;
      for (let i: number = 0; i < n; i += len) {
        for (let j: number = 0; j < half; j++) {
          // The line that costs everything: recomputed N/2 times per stage.
          const angle: number = -TWO_PI * j / len;
          const wr: number = Math.cos(angle);
          const wi: number = Math.sin(angle);

          const a: number = i + j;
          const b: number = a + half;
          const rb: number = re[b];
          const ib: number = im[b];
          const tr: number = rb * wr - ib * wi;
          const ti: number = rb * wi + ib * wr;

          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] = re[a] + tr;
          im[a] = im[a] + ti;
        }
      }
    }
  }
}
