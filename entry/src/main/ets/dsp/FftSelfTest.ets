/*
 * dsp/FftSelfTest.ets — proof that the transform is actually correct.
 *
 * Imports only its siblings inside dsp/, nothing outside it, so the folder stays
 * copy-paste portable as a unit.
 *
 * Why this file exists at all: a hand-written FFT with a subtle index bug still produces
 * output that LOOKS like a spectrum. Bars in roughly the right places, a peak near where
 * you expected one. Eyeballing the display proves nothing. These eight checks pin down
 * every property the transform is supposed to have, and the last one compares against a
 * direct O(N^2) DFT — which is slow but obviously correct, and therefore the strongest
 * check available.
 *
 * The same assertions run as hypium unit tests in entry/src/test/FftTest.ets. They live
 * here as well so they can run on-device, where the arithmetic actually executes.
 */

import { Fft } from './Fft';
import { Spectrum } from './Spectrum';
import { WindowFunction, WindowType } from './Window';

export interface SelfTestResult {
  name: string;
  passed: boolean;
  /** Measured error or observed value — shown next to the verdict, pass or fail. */
  detail: string;
}

export interface SelfTestReport {
  results: SelfTestResult[];
  passed: number;
  failed: number;
  durationMs: number;
}

/** Deterministic pseudo-random source, so a failure is always reproducible. */
class Lcg {
  private state: number;

  constructor(seed: number) {
    this.state = seed >>> 0;
  }

  /** Uniform in [-1, 1). */
  nextSigned(): number {
    this.state = (Math.imul(this.state, 1664525) + 1013904223) >>> 0;
    return (this.state / 2147483648) - 1;
  }
}

function result(name: string, passed: boolean, detail: string): SelfTestResult {
  const r: SelfTestResult = { name: name, passed: passed, detail: detail };
  return r;
}

function fmt(value: number): string {
  if (value === 0) {
    return '0';
  }
  const abs: number = Math.abs(value);
  if (abs < 1e-4 || abs >= 1e5) {
    return value.toExponential(2);
  }
  return value.toFixed(6);
}

export class FftSelfTest {

  /** Runs every check at the given transform size and reports what it measured. */
  static runAll(size: number): SelfTestReport {
    const started: number = Date.now();
    const results: SelfTestResult[] = [];

    results.push(FftSelfTest.dcInput(size));
    results.push(FftSelfTest.impulse(size));
    results.push(FftSelfTest.exactBinSine(size));
    results.push(FftSelfTest.betweenBinSine(size));
    results.push(FftSelfTest.linearity(size));
    results.push(FftSelfTest.parseval(size));
    results.push(FftSelfTest.roundTrip(size));
    results.push(FftSelfTest.matchesDirectDft());

    let passed: number = 0;
    for (let i: number = 0; i < results.length; i++) {
      if (results[i].passed) {
        passed++;
      }
    }

    const report: SelfTestReport = {
      results: results,
      passed: passed,
      failed: results.length - passed,
      durationMs: Date.now() - started
    };
    return report;
  }

  /** Constant input: every sample identical. All energy belongs in bin 0. */
  static dcInput(size: number): SelfTestResult {
    const fft = new Fft(size);
    const re = new Float64Array(size);
    const im = new Float64Array(size);
    re.fill(1);
    fft.forward(re, im);

    const dcError: number = Math.abs(re[0] - size) + Math.abs(im[0]);
    let leakage: number = 0;
    for (let k: number = 1; k < size; k++) {
      leakage = Math.max(leakage, Math.abs(re[k]), Math.abs(im[k]));
    }

    const ok: boolean = dcError < 1e-9 && leakage < 1e-9;
    return result('DC input', ok, `bin0 err ${fmt(dcError)}, leak ${fmt(leakage)}`);
  }

  /** Unit impulse at n=0: the spectrum is flat, every bin exactly 1. */
  static impulse(size: number): SelfTestResult {
    const fft = new Fft(size);
    const re = new Float64Array(size);
    const im = new Float64Array(size);
    re[0] = 1;
    fft.forward(re, im);

    let worst: number = 0;
    for (let k: number = 0; k < size; k++) {
      const mag: number = Math.sqrt(re[k] * re[k] + im[k] * im[k]);
      worst = Math.max(worst, Math.abs(mag - 1));
    }

    const ok: boolean = worst < 1e-12;
    return result('Impulse -> flat', ok, `max |mag-1| ${fmt(worst)}`);
  }

  /**
   * A cosine sitting exactly on a bin centre. Tests both halves of the scaling in
   * Spectrum.compute: the peak lands on the right bin AND the amplitude comes back out.
   */
  static exactBinSine(size: number): SelfTestResult {
    const sampleRate: number = 44100;
    const targetBin: number = Math.floor(size / 8);
    const amplitude: number = 0.5;

    const fft = new Fft(size);
    const spectrum = new Spectrum(size);
    const re = new Float64Array(size);
    const im = new Float64Array(size);

    for (let n: number = 0; n < size; n++) {
      re[n] = amplitude * Math.cos(6.283185307179586 * targetBin * n / size);
      im[n] = 0;
    }
    fft.forward(re, im);
    spectrum.compute(re, im, 1);   // rectangular window: coherent gain 1

    const peak = spectrum.findPeak(sampleRate, 0, sampleRate / 2);
    const recovered: number = Math.pow(10, peak.magnitudeDb / 20);
    const ampError: number = Math.abs(recovered - amplitude);

    const ok: boolean = peak.binIndex === targetBin && ampError < 1e-9;
    return result(
      'Sine on bin centre',
      ok,
      `bin ${peak.binIndex}/${targetBin}, amp err ${fmt(ampError)}`
    );
  }

  /**
   * A cosine deliberately placed 0.37 bins off centre — the case that makes raw bin
   * indices useless and parabolic interpolation worth writing.
   */
  static betweenBinSine(size: number): SelfTestResult {
    const sampleRate: number = 44100;
    const trueBin: number = Math.floor(size / 8) + 0.37;
    const trueHz: number = trueBin * sampleRate / size;

    const fft = new Fft(size);
    const spectrum = new Spectrum(size);
    const window = new WindowFunction(WindowType.HANN, size);
    const samples = new Float64Array(size);
    const re = new Float64Array(size);
    const im = new Float64Array(size);

    for (let n: number = 0; n < size; n++) {
      samples[n] = 0.5 * Math.cos(6.283185307179586 * trueBin * n / size);
    }
    window.apply(samples, samples);
    fft.forwardReal(samples, re, im);
    spectrum.compute(re, im, window.coherentGain);

    const peak = spectrum.findPeak(sampleRate, 0, sampleRate / 2);
    const rawErrorHz: number = Math.abs(peak.binHz - trueHz);
    const interpErrorHz: number = Math.abs(peak.frequencyHz - trueHz);
    const relError: number = interpErrorHz / trueHz;

    // Interpolation must not only be accurate, it must beat the raw bin it came from.
    const ok: boolean = relError < 0.005 && interpErrorHz < rawErrorHz;
    return result(
      'Sine between bins',
      ok,
      `raw off ${fmt(rawErrorHz)} Hz -> interp off ${fmt(interpErrorHz)} Hz`
    );
  }

  /** FFT(a*x + b*y) must equal a*FFT(x) + b*FFT(y). */
  static linearity(size: number): SelfTestResult {
    const a: number = 0.3;
    const b: number = -0.7;
    const rng = new Lcg(20260916);

    const fft = new Fft(size);
    const xr = new Float64Array(size);
    const xi = new Float64Array(size);
    const yr = new Float64Array(size);
    const yi = new Float64Array(size);
    const cr = new Float64Array(size);
    const ci = new Float64Array(size);

    for (let n: number = 0; n < size; n++) {
      xr[n] = rng.nextSigned();
      yr[n] = rng.nextSigned();
      cr[n] = a * xr[n] + b * yr[n];
    }

    fft.forward(xr, xi);
    fft.forward(yr, yi);
    fft.forward(cr, ci);

    let worst: number = 0;
    for (let k: number = 0; k < size; k++) {
      worst = Math.max(
        worst,
        Math.abs(cr[k] - (a * xr[k] + b * yr[k])),
        Math.abs(ci[k] - (a * xi[k] + b * yi[k]))
      );
    }

    const ok: boolean = worst < 1e-9;
    return result('Linearity', ok, `max deviation ${fmt(worst)}`);
  }

  /**
   * Parseval's theorem: the transform moves energy between domains, it doesn't create or
   * destroy any. sum(x[n]^2) == (1/N) * sum(|X[k]|^2) over all N bins.
   */
  static parseval(size: number): SelfTestResult {
    const rng = new Lcg(777);
    const fft = new Fft(size);
    const re = new Float64Array(size);
    const im = new Float64Array(size);

    let timeEnergy: number = 0;
    for (let n: number = 0; n < size; n++) {
      re[n] = rng.nextSigned();
      timeEnergy += re[n] * re[n];
    }

    fft.forward(re, im);

    let freqEnergy: number = 0;
    for (let k: number = 0; k < size; k++) {
      freqEnergy += re[k] * re[k] + im[k] * im[k];
    }
    freqEnergy /= size;

    const relError: number = Math.abs(freqEnergy - timeEnergy) / timeEnergy;
    const ok: boolean = relError < 1e-10;
    return result('Parseval energy', ok, `relative err ${fmt(relError)}`);
  }

  /** Forward then inverse must return the original samples. */
  static roundTrip(size: number): SelfTestResult {
    const rng = new Lcg(31337);
    const fft = new Fft(size);
    const re = new Float64Array(size);
    const im = new Float64Array(size);
    const original = new Float64Array(size);

    for (let n: number = 0; n < size; n++) {
      const v: number = rng.nextSigned();
      re[n] = v;
      original[n] = v;
    }

    fft.forward(re, im);
    fft.inverse(re, im);

    let worst: number = 0;
    for (let n: number = 0; n < size; n++) {
      worst = Math.max(worst, Math.abs(re[n] - original[n]), Math.abs(im[n]));
    }

    const ok: boolean = worst < 1e-10;
    return result('Forward -> inverse', ok, `max round-trip err ${fmt(worst)}`);
  }

  /**
   * The check that subsumes all the others: compare against a direct DFT computed
   * straight from the definition. Slow — O(N^2) — so it runs at N=64, but it depends on
   * none of the machinery under test. If the bit-reversal table or a twiddle stride were
   * wrong, this is what would catch it.
   */
  static matchesDirectDft(): SelfTestResult {
    const n: number = 64;
    const rng = new Lcg(4242);
    const fft = new Fft(n);
    const re = new Float64Array(n);
    const im = new Float64Array(n);
    const srcRe = new Float64Array(n);
    const srcIm = new Float64Array(n);

    for (let i: number = 0; i < n; i++) {
      const r: number = rng.nextSigned();
      const m: number = rng.nextSigned();
      re[i] = r;
      im[i] = m;
      srcRe[i] = r;
      srcIm[i] = m;
    }

    fft.forward(re, im);

    let worst: number = 0;
    for (let k: number = 0; k < n; k++) {
      let sumRe: number = 0;
      let sumIm: number = 0;
      for (let t: number = 0; t < n; t++) {
        const angle: number = -6.283185307179586 * k * t / n;
        const c: number = Math.cos(angle);
        const s: number = Math.sin(angle);
        sumRe += srcRe[t] * c - srcIm[t] * s;
        sumIm += srcRe[t] * s + srcIm[t] * c;
      }
      worst = Math.max(worst, Math.abs(re[k] - sumRe), Math.abs(im[k] - sumIm));
    }

    const ok: boolean = worst < 1e-9;
    return result('Matches direct DFT (N=64)', ok, `max deviation ${fmt(worst)}`);
  }
}
