/*
 * common/SpectrumStore.ets — the latest analysis result, held where the UI can read it.
 *
 * AnalysisUpdate hands out buffers the engine still owns and will overwrite on the next
 * frame. Anything the UI draws later — and a Canvas always draws later — has to read from
 * its own copy. This is that copy.
 *
 * A plain class, not @Observed: the interesting change is the CONTENTS of a Float64Array,
 * which ArkUI's observation cannot see. Components are told to redraw by a separate
 * @State version counter that the page increments after each update() call.
 */

import { PeakEstimate, DB_FLOOR } from '../dsp/Spectrum';
import { EngineStats } from './types';
import { AnalysisUpdate } from '../engine/AnalyzerController';

/** Sized for the largest supported transform so no resize is needed at runtime. */
const MAX_BINS: number = 4096 / 2 + 1;

export class SpectrumStore {
  readonly decibels: Float64Array = new Float64Array(MAX_BINS);
  binCount: number = 0;
  sampleRate: number = 44100;
  fftSize: number = 4096;

  peak: PeakEstimate = {
    binIndex: -1, binHz: 0, frequencyHz: 0, magnitudeDb: DB_FLOOR, binOffset: 0
  };

  stats: EngineStats = {
    lastMs: 0, averageMs: 0, maxMs: 0, framesPerSecond: 0, framesAnalysed: 0, framesDropped: 0
  };

  constructor() {
    this.decibels.fill(DB_FLOOR);
  }

  update(u: AnalysisUpdate): void {
    const count: number = Math.min(u.binCount, MAX_BINS);
    this.decibels.set(u.decibels.subarray(0, count));
    this.binCount = count;
    this.sampleRate = u.sampleRate;
    this.fftSize = u.fftSize;
    this.peak = u.peak;
    this.stats = u.stats;
  }

  /** Centre frequency of a bin, for axis labelling. */
  binToHz(bin: number): number {
    return bin * this.sampleRate / this.fftSize;
  }

  binWidthHz(): number {
    return this.sampleRate / this.fftSize;
  }

  nyquistHz(): number {
    return this.sampleRate / 2;
  }
}
