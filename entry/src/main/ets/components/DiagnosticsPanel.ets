/*
 * components/DiagnosticsPanel.ets — measured numbers, not estimates.
 *
 * Two things live here that a codelab normally leaves as prose claims:
 *
 *   - The self-test, so "this FFT is correct" is something you can press a button and
 *     verify on the device in front of you.
 *   - The twiddle-table benchmark, so "precomputing the twiddles is worth it" is a
 *     measured ratio on your hardware rather than a number from someone else's laptop.
 */

import { ArcList, ArcListAttribute, ArcListItem, ArcListItemAttribute } from '@kit.ArkUI';
import { Palette, Type } from '../common/Theme';
import { formatMs } from '../common/Format';
import { hasHighResolutionClock, nowMs } from '../common/Clock';
import { SpectrumStore } from '../common/SpectrumStore';
import { EngineStats } from '../common/types';
import { Fft, NaiveFft } from '../dsp/Fft';
import { FftSelfTest, SelfTestReport, SelfTestResult } from '../dsp/FftSelfTest';

/** Iteration counts for the benchmark. The naive path gets fewer — it is much slower. */
const FAST_ITERATIONS: number = 30;
const NAIVE_ITERATIONS: number = 8;

interface BenchResult {
  tableMs: number;
  naiveMs: number;
  speedup: number;
}

@Component
export struct DiagnosticsPanel {
  /**
   * Bumped by the page after every analysed frame.
   *
   * The @Watch is what makes this work, and it is not optional. ArkUI registers a redraw
   * dependency on the state a build() actually READS, and nothing below reads `version` —
   * every figure comes from `store`, which is deliberately not @Observed. A bare @Prop
   * would therefore be written every frame and repaint nothing, leaving this page frozen
   * on the first set of numbers it ever saw.
   */
  @Prop @Watch('onVersionChanged') version: number = 0;
  @Prop engineLabel: string = '';

  store: SpectrumStore = new SpectrumStore();

  /** The store's statistics, mirrored where ArkUI can see them change. */
  @State private stats: EngineStats = {
    lastMs: 0, averageMs: 0, maxMs: 0, framesPerSecond: 0, framesAnalysed: 0, framesDropped: 0
  };

  onVersionChanged(): void {
    // buildStats returns a fresh object per frame, so the reference always differs and
    // the assignment is never elided.
    this.stats = this.store.stats;
  }

  @State private report: SelfTestReport | undefined = undefined;
  @State private bench: BenchResult | undefined = undefined;
  @State private busy: boolean = false;

  build() {
    ArcList({ initialIndex: 0 }) {
      ArcListItem() {
        Text(`${this.engineLabel}`)
          .fontSize(Type.LABEL)
          .fontColor(Palette.MUTED);
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.statRow('last frame', formatMs(this.stats.lastMs));
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.statRow('average', formatMs(this.stats.averageMs));
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.statRow('max', formatMs(this.stats.maxMs));
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.statRow('frames/s', this.stats.framesPerSecond.toFixed(1));
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.statRow('analysed', `${this.stats.framesAnalysed}`);
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.statRow('dropped', `${this.stats.framesDropped}`);
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.statRow('clock', hasHighResolutionClock() ? 'nanosecond' : 'millisecond');
      }
      .align(Alignment.Center);

      // --- self-test ---------------------------------------------------------------
      ArcListItem() {
        Button(this.busy ? 'Running...' : 'Run self-test')
          .fontSize(Type.LABEL)
          .width('72%')
          .height(28)
          .enabled(!this.busy)
          .backgroundColor(Palette.PANEL)
          .fontColor(Palette.ACCENT)
          .onClick(() => this.runSelfTest());
      }
      .align(Alignment.Center);

      if (this.report !== undefined) {
        ArcListItem() {
          Text(`${this.report.passed}/${this.report.results.length} passed in ${this.report.durationMs} ms`)
            .fontSize(Type.LABEL)
            .fontColor(this.report.failed === 0 ? Palette.GOOD : Palette.BAD);
        }
        .align(Alignment.Center);

        ForEach(this.report.results, (item: SelfTestResult) => {
          ArcListItem() {
            Column({ space: 1 }) {
              Row() {
                Text(item.passed ? 'PASS' : 'FAIL')
                  .fontSize(Type.TINY)
                  .fontColor(item.passed ? Palette.GOOD : Palette.BAD);
                Text(item.name)
                  .fontSize(Type.TINY)
                  .fontColor(Palette.TEXT)
                  .margin({ left: 5 });
              };
              Text(item.detail)
                .fontSize(Type.TINY)
                .fontColor(Palette.MUTED);
            }
            .width('80%')
            .alignItems(HorizontalAlign.Start);
          }
          .align(Alignment.Center);
        }, (item: SelfTestResult) => item.name);
      }

      // --- twiddle-table benchmark -------------------------------------------------
      ArcListItem() {
        Button(this.busy ? 'Running...' : 'Benchmark tables')
          .fontSize(Type.LABEL)
          .width('72%')
          .height(28)
          .enabled(!this.busy)
          .backgroundColor(Palette.PANEL)
          .fontColor(Palette.ACCENT)
          .onClick(() => this.runBenchmark());
      }
      .align(Alignment.Center);

      if (this.bench !== undefined) {
        ArcListItem() {
          this.statRow('tables', formatMs(this.bench.tableMs));
        }
        .align(Alignment.Center);

        ArcListItem() {
          this.statRow('Math.cos', formatMs(this.bench.naiveMs));
        }
        .align(Alignment.Center);

        ArcListItem() {
          Text(`precomputing is ${this.bench.speedup.toFixed(1)}x faster`)
            .fontSize(Type.LABEL)
            .fontColor(Palette.ACCENT)
            .textAlign(TextAlign.Center);
        }
        .align(Alignment.Center);
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  statRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(Type.LABEL)
        .fontColor(Palette.MUTED);
      Blank();
      Text(value)
        .fontSize(Type.LABEL)
        .fontColor(Palette.TEXT);
    }
    .width('78%')
    .height(24)
    .padding({ left: 10, right: 10 });
  }

  /**
   * Runs on the UI thread and blocks it for a moment. That is acceptable for an explicit
   * button press, and keeping it synchronous means the reported duration is the real
   * arithmetic cost with no scheduling noise mixed in.
   */
  private runSelfTest(): void {
    this.busy = true;
    this.report = FftSelfTest.runAll(this.store.fftSize);
    this.busy = false;
  }

  private runBenchmark(): void {
    this.busy = true;

    const n: number = this.store.fftSize;
    const fast = new Fft(n);
    const naive = new NaiveFft(n);
    const re = new Float64Array(n);
    const im = new Float64Array(n);
    const source = new Float64Array(n);
    for (let i: number = 0; i < n; i++) {
      source[i] = Math.sin(i * 0.05);
    }

    // One untimed pass each, so JIT warmup doesn't land inside the measurement.
    re.set(source);
    im.fill(0);
    fast.forward(re, im);
    re.set(source);
    im.fill(0);
    naive.forward(re, im);

    const fastStart: number = nowMs();
    for (let i: number = 0; i < FAST_ITERATIONS; i++) {
      re.set(source);
      im.fill(0);
      fast.forward(re, im);
    }
    const tableMs: number = (nowMs() - fastStart) / FAST_ITERATIONS;

    const naiveStart: number = nowMs();
    for (let i: number = 0; i < NAIVE_ITERATIONS; i++) {
      re.set(source);
      im.fill(0);
      naive.forward(re, im);
    }
    const naiveMs: number = (nowMs() - naiveStart) / NAIVE_ITERATIONS;

    const result: BenchResult = {
      tableMs: tableMs,
      naiveMs: naiveMs,
      speedup: tableMs > 0 ? naiveMs / tableMs : 0
    };
    this.bench = result;
    this.busy = false;
  }
}
