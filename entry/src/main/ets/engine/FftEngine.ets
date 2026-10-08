/*
 * engine/FftEngine.ets — one frame in, one spectrum out.
 *
 * Owns every buffer the analysis path touches and reuses all of them, so a steady stream
 * of frames allocates nothing. Changing N or the window rebuilds the tables once; steady
 * state never does.
 */

import { Fft } from '../dsp/Fft';
import { Spectrum } from '../dsp/Spectrum';
import { WindowFunction, WindowType } from '../dsp/Window';

export class FftEngine {
  private fft: Fft;
  private window: WindowFunction;
  private spectrumOut: Spectrum;

  // Scratch, allocated once per size change.
  private windowed: Float64Array;
  private re: Float64Array;
  private im: Float64Array;

  private currentSize: number;
  private currentWindow: WindowType;

  constructor(fftSize: number, windowType: WindowType) {
    this.currentSize = fftSize;
    this.currentWindow = windowType;
    this.fft = new Fft(fftSize);
    this.window = new WindowFunction(windowType, fftSize);
    this.spectrumOut = new Spectrum(fftSize);
    this.windowed = new Float64Array(fftSize);
    this.re = new Float64Array(fftSize);
    this.im = new Float64Array(fftSize);
  }

  get size(): number {
    return this.currentSize;
  }

  get spectrum(): Spectrum {
    return this.spectrumOut;
  }

  get coherentGain(): number {
    return this.window.coherentGain;
  }

  get windowType(): WindowType {
    return this.currentWindow;
  }

  /** Rebuild for a new transform length. Cheap enough to call from a UI handler. */
  setSize(fftSize: number): void {
    if (fftSize === this.currentSize) {
      return;
    }
    this.currentSize = fftSize;
    this.fft = new Fft(fftSize);
    this.window = new WindowFunction(this.currentWindow, fftSize);
    this.spectrumOut = new Spectrum(fftSize);
    this.windowed = new Float64Array(fftSize);
    this.re = new Float64Array(fftSize);
    this.im = new Float64Array(fftSize);
  }

  /** Swap the analysis window. Only the coefficient table is rebuilt. */
  setWindow(windowType: WindowType): void {
    if (windowType === this.currentWindow) {
      return;
    }
    this.currentWindow = windowType;
    this.window = new WindowFunction(windowType, this.currentSize);
  }

  /**
   * Window, transform, and reduce to a magnitude spectrum. `frame` must hold at least
   * `size` samples; anything beyond that is ignored.
   *
   * The frame is copied into scratch rather than tapered in place, because FrameAssembler
   * hands out a buffer it still owns and will overwrite on the next hop.
   */
  analyze(frame: Float64Array): void {
    const n: number = this.currentSize;
    const windowed = this.windowed;
    const coeffs = this.window.coefficients;

    for (let i: number = 0; i < n; i++) {
      windowed[i] = frame[i] * coeffs[i];
    }

    this.fft.forwardReal(windowed, this.re, this.im);
    this.spectrumOut.compute(this.re, this.im, this.window.coherentGain);
  }
}
