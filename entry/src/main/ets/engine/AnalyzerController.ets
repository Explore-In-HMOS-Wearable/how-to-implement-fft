/*
 * engine/AnalyzerController.ets — wires a sample source to the transform and publishes
 * the result.
 *
 * Deliberately not an @Observed class. ArkUI's observation tracks property assignment,
 * and the payload here is a Float64Array whose CONTENTS change every frame while the
 * reference stays the same — exactly the case @Observed does not see. Pushing updates
 * through an explicit callback keeps that honest instead of producing a display that
 * mysteriously never refreshes.
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Spectrum, PeakEstimate } from '../dsp/Spectrum';
import { WindowType } from '../dsp/Window';
import { FftEngine } from './FftEngine';
import { TaskPoolAnalyzer } from './FftTask';
import { FrameAssembler } from '../audio/FrameAssembler';
import { SignalGenerator } from '../audio/SignalGenerator';
import { MicSource, MicStartResult, requestMicPermission } from '../audio/MicSource';
import { nowMs } from '../common/Clock';
import { EngineMode, EngineStats, PEAK_MIN_HZ, SignalKind, SourceKind } from '../common/types';

const DOMAIN: number = 0x0000;
const TAG: string = 'Analyzer';

/** How many recent frame timings feed the rolling average. */
const TIMING_WINDOW: number = 32;

/**
 * Idle the synthetic loop always leaves the UI thread between blocks, even when a block
 * already overran its hop. Without a guaranteed gap the main thread never returns to the
 * event loop, input goes unanswered, and the system kills the app with APP_INPUT_BLOCK.
 */
const MIN_IDLE_MS: number = 16;

/**
 * Largest share of the UI thread the analysis loop will take when it cannot keep up.
 * A block that overruns its hop earns a proportional cooldown, so touch and rendering
 * still get a third of the thread instead of whatever is left over.
 */
const MAX_DUTY: number = 2 / 3;

/**
 * Ceiling on how often the UI is told to redraw. Analysis may legitimately run faster —
 * at N = 256 a hop is under 3 ms — but a watch cannot repaint a canvas 300 times a
 * second, and trying is what starves everything else.
 */
const UI_PUBLISH_MS: number = 50;

export interface AnalysisUpdate {
  /** dBFS per bin. Valid only for the duration of the callback — copy it if you keep it. */
  decibels: Float64Array;
  binCount: number;
  peak: PeakEstimate;
  stats: EngineStats;
  sampleRate: number;
  fftSize: number;
}

export class AnalyzerController {
  // --- configuration ---
  private sourceKind: SourceKind = SourceKind.SYNTHETIC;
  private engineMode: EngineMode = EngineMode.MAIN_THREAD;
  private fftSize: number = 4096;
  private hopDivisor: number = 2;          // hop = fftSize / hopDivisor
  private sampleRate: number = 44100;

  // --- machinery ---
  private engine: FftEngine;
  private assembler: FrameAssembler;
  private generator: SignalGenerator;
  private taskAnalyzer: TaskPoolAnalyzer = new TaskPoolAnalyzer();
  private mic: MicSource = new MicSource();
  /** Holds a copy of worker-returned dB values so findPeak can run on the main thread. */
  private peakFinder: Spectrum;
  private generatorBlock: Float64Array;

  // --- runtime state ---
  private running: boolean = false;
  private timerId: number = -1;
  /** Target spacing between synthetic blocks — one hop's worth of real time. */
  private hopMs: number = MIN_IDLE_MS;
  private lastPublishMs: number = 0;
  private onUpdate: ((update: AnalysisUpdate) => void) | undefined = undefined;
  private statusMessage: string = 'Synthetic 440 Hz sine. Swipe for controls.';

  // --- statistics ---
  private timings: Float64Array = new Float64Array(TIMING_WINDOW);
  private timingCount: number = 0;
  private timingPos: number = 0;
  private maxMs: number = 0;
  private framesAnalysed: number = 0;
  private fpsWindowStart: number = 0;
  private fpsWindowFrames: number = 0;
  private framesPerSecond: number = 0;

  constructor() {
    this.engine = new FftEngine(this.fftSize, WindowType.HANN);
    this.assembler = new FrameAssembler(this.fftSize, this.hopSize());
    this.generator = new SignalGenerator(this.sampleRate);
    this.peakFinder = new Spectrum(this.fftSize);
    this.generatorBlock = new Float64Array(this.hopSize());
  }

  // ---------------------------------------------------------------- accessors

  hopSize(): number {
    return Math.max(1, Math.floor(this.fftSize / this.hopDivisor));
  }

  getFftSize(): number {
    return this.fftSize;
  }

  getSampleRate(): number {
    return this.sampleRate;
  }

  getSourceKind(): SourceKind {
    return this.sourceKind;
  }

  getEngineMode(): EngineMode {
    return this.engineMode;
  }

  getWindowType(): WindowType {
    return this.engine.windowType;
  }

  getSignalKind(): SignalKind {
    return this.generator.getKind();
  }

  getSignalFrequency(): number {
    return this.generator.getFrequency();
  }

  getStatus(): string {
    return this.statusMessage;
  }

  isRunning(): boolean {
    return this.running;
  }

  /** Bin spacing in Hz — the resolution limit before interpolation. */
  binWidthHz(): number {
    return this.sampleRate / this.fftSize;
  }

  setOnUpdate(callback: (update: AnalysisUpdate) => void): void {
    this.onUpdate = callback;
  }

  // ---------------------------------------------------------------- lifecycle

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return;
    }
    this.resetStats();
    this.assembler.reset();

    if (this.sourceKind === SourceKind.MICROPHONE) {
      const granted: boolean = await requestMicPermission(context);
      if (!granted) {
        this.statusMessage = 'Microphone denied. Switch back to Synthetic.';
        return;
      }
      const result: MicStartResult = await this.mic.start((buffer: ArrayBuffer) => {
        this.assembler.pushInt16(buffer, (frame: Float64Array) => this.onFrame(frame));
      });
      if (!result.started) {
        this.statusMessage = `Mic unavailable — ${result.message}`;
        return;
      }
      this.applySampleRate(result.sampleRate);
      this.statusMessage = `Live mic at ${result.sampleRate} Hz.`;
      this.running = true;
      return;
    }

    // Synthetic: a self-rescheduling timer paced to one hop, so frames arrive at the same
    // rate live audio would deliver them.
    this.hopMs = Math.max(MIN_IDLE_MS, Math.round(this.hopSize() * 1000 / this.sampleRate));
    this.statusMessage = `Synthetic source, one frame per ${this.hopMs} ms.`;
    this.running = true;
    this.scheduleTick(0);
  }

  async stop(): Promise<void> {
    this.running = false;
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    await this.mic.stop();
  }

  /** Stop, apply a change, and start again if it was running. */
  async restart(context: common.UIAbilityContext): Promise<void> {
    const wasRunning: boolean = this.running;
    await this.stop();
    if (wasRunning) {
      await this.start(context);
    }
  }

  // ---------------------------------------------------------------- settings

  setFftSize(size: number): void {
    if (size === this.fftSize) {
      return;
    }
    this.fftSize = size;
    this.engine.setSize(size);
    this.peakFinder = new Spectrum(size);
    this.assembler = new FrameAssembler(size, this.hopSize());
    this.generatorBlock = new Float64Array(this.hopSize());
    this.resetStats();
  }

  setHopDivisor(divisor: number): void {
    if (divisor === this.hopDivisor) {
      return;
    }
    this.hopDivisor = divisor;
    this.assembler = new FrameAssembler(this.fftSize, this.hopSize());
    this.generatorBlock = new Float64Array(this.hopSize());
    this.resetStats();
  }

  getHopDivisor(): number {
    return this.hopDivisor;
  }

  setWindowType(type: WindowType): void {
    this.engine.setWindow(type);
  }

  setEngineMode(mode: EngineMode): void {
    this.engineMode = mode;
    this.taskAnalyzer.resetCounters();
    this.resetStats();
  }

  setSourceKind(kind: SourceKind): void {
    this.sourceKind = kind;
    if (kind === SourceKind.SYNTHETIC) {
      this.applySampleRate(44100);
    }
  }

  setSignalKind(kind: SignalKind): void {
    this.generator.setKind(kind);
  }

  setSignalFrequency(hz: number): void {
    this.generator.setFrequency(hz);
  }

  /** What the synthetic source says the peak should be — 0 when there isn't one. */
  expectedPeakHz(): number {
    return this.sourceKind === SourceKind.SYNTHETIC ? this.generator.expectedPeakHz() : 0;
  }

  private applySampleRate(rate: number): void {
    this.sampleRate = rate;
    this.generator.setSampleRate(rate);
  }

  // ---------------------------------------------------------------- analysis

  private scheduleTick(delayMs: number): void {
    this.timerId = setTimeout(() => this.tick(), delayMs);
  }

  /**
   * One block of synthetic samples, then the next tick is booked.
   *
   * Deliberately setTimeout-after-the-work rather than setInterval. setInterval keeps
   * posting on its own schedule regardless of how long the previous callback took, so
   * once a block costs more than a hop — an easy thing at N = 4096 on a watch CPU with
   * no AOT image — callbacks queue up faster than they drain. The main thread then never
   * reaches the event loop again, input goes unanswered, and the system kills the app
   * with APP_INPUT_BLOCK. Rescheduling from the end instead means a slow device simply
   * analyses less often, which is the correct way to degrade.
   */
  private tick(): void {
    this.timerId = -1;
    if (!this.running) {
      return;
    }
    const started: number = nowMs();
    this.generateBlock();
    const spent: number = nowMs() - started;

    const paced: number = this.hopMs - spent;
    const cooldown: number = spent * (1 - MAX_DUTY) / MAX_DUTY;
    this.scheduleTick(Math.max(MIN_IDLE_MS, paced, cooldown));
  }

  private generateBlock(): void {
    const hop: number = this.hopSize();
    this.generator.fill(this.generatorBlock, hop);
    this.assembler.pushFloat(this.generatorBlock, hop, (frame: Float64Array) => this.onFrame(frame));
  }

  private onFrame(frame: Float64Array): void {
    if (this.engineMode === EngineMode.TASK_POOL) {
      this.analyzeOnPool(frame);
    } else {
      this.analyzeOnMain(frame);
    }
  }

  private analyzeOnMain(frame: Float64Array): void {
    const started: number = nowMs();
    this.engine.analyze(frame);
    const elapsed: number = nowMs() - started;

    const spectrum: Spectrum = this.engine.spectrum;
    const peak: PeakEstimate = spectrum.findPeak(this.sampleRate, PEAK_MIN_HZ, this.sampleRate / 2);
    this.publish(spectrum.decibels, spectrum.binCount, peak, elapsed);
  }

  /**
   * Timed from dispatch to resolution, not just the transform. That is the number the app
   * actually experiences — it includes queueing, the transfer, and the copy back — and
   * it's the only fair comparison against the main-thread path.
   */
  private analyzeOnPool(frame: Float64Array): void {
    const started: number = nowMs();
    this.taskAnalyzer.analyze(frame, this.fftSize, this.engine.windowType)
      .then((decibels: Float64Array | undefined) => {
        if (decibels === undefined || !this.running) {
          return;   // dropped: the pool was still busy with the previous frame
        }
        const elapsed: number = nowMs() - started;
        const finder: Spectrum = this.peakFinder;
        finder.decibels.set(decibels.subarray(0, finder.binCount));
        const peak: PeakEstimate = finder.findPeak(this.sampleRate, PEAK_MIN_HZ, this.sampleRate / 2);
        this.publish(decibels, finder.binCount, peak, elapsed);
      })
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'TaskPool analyze failed: %{public}s', err.message);
      });
  }

  private publish(
    decibels: Float64Array,
    binCount: number,
    peak: PeakEstimate,
    elapsedMs: number
  ): void {
    this.recordTiming(elapsedMs);

    const callback = this.onUpdate;
    if (callback === undefined) {
      return;
    }

    // Analysis keeps its own pace; the display does not have to follow it frame for
    // frame. Every publish bumps a version counter the whole page observes, so an
    // unthrottled one at a 3 ms hop asks for hundreds of full relayouts a second.
    const now: number = nowMs();
    if (now - this.lastPublishMs < UI_PUBLISH_MS) {
      return;
    }
    this.lastPublishMs = now;

    const update: AnalysisUpdate = {
      decibels: decibels,
      binCount: binCount,
      peak: peak,
      stats: this.buildStats(elapsedMs),
      sampleRate: this.sampleRate,
      fftSize: this.fftSize
    };
    callback(update);
  }

  // ---------------------------------------------------------------- statistics

  private resetStats(): void {
    this.timings.fill(0);
    this.timingCount = 0;
    this.timingPos = 0;
    this.maxMs = 0;
    this.framesAnalysed = 0;
    this.fpsWindowStart = nowMs();
    this.fpsWindowFrames = 0;
    this.framesPerSecond = 0;
    this.lastPublishMs = 0;
    this.taskAnalyzer.resetCounters();
  }

  private recordTiming(ms: number): void {
    this.timings[this.timingPos] = ms;
    this.timingPos = (this.timingPos + 1) % TIMING_WINDOW;
    if (this.timingCount < TIMING_WINDOW) {
      this.timingCount++;
    }
    // The first frame carries cold-start cost (JIT warmup, first worker dispatch), so it
    // is excluded from the max to keep that figure representative of steady state.
    if (this.framesAnalysed > 0 && ms > this.maxMs) {
      this.maxMs = ms;
    }
    this.framesAnalysed++;

    this.fpsWindowFrames++;
    const now: number = nowMs();
    const span: number = now - this.fpsWindowStart;
    if (span >= 1000) {
      this.framesPerSecond = this.fpsWindowFrames * 1000 / span;
      this.fpsWindowStart = now;
      this.fpsWindowFrames = 0;
    }
  }

  private buildStats(lastMs: number): EngineStats {
    let sum: number = 0;
    for (let i: number = 0; i < this.timingCount; i++) {
      sum += this.timings[i];
    }
    const stats: EngineStats = {
      lastMs: lastMs,
      averageMs: this.timingCount > 0 ? sum / this.timingCount : 0,
      maxMs: this.maxMs,
      framesPerSecond: this.framesPerSecond,
      framesAnalysed: this.framesAnalysed,
      framesDropped: this.taskAnalyzer.droppedFrames
    };
    return stats;
  }
}
