/*
 * components/SpectrumCanvas.ets — the magnitude spectrum, drawn on a Canvas.
 *
 * Canvas rather than a component tree: at N = 4096 there are 2049 bins arriving ~21 times
 * a second. Pushing that through ArkUI's diffing as 200-odd Rect components would spend
 * far more time in layout than in the FFT it is meant to display.
 *
 * The x axis is logarithmic. A linear axis devotes half its width to 11-22 kHz, where
 * there is usually nothing to see, and crushes the octaves that matter into the leftmost
 * few pixels. Log spacing gives every octave equal width, which is also how pitch works.
 */

import { SpectrumStore } from '../common/SpectrumStore';
import { Palette, Type } from '../common/Theme';
import { DB_FLOOR } from '../dsp/Spectrum';

/** Display floor. Below this is noise on a wearable mic; showing it just adds grass. */
const DB_MIN: number = -90;
const DB_MAX: number = 0;

/** Lowest frequency plotted. Under this is DC offset and handling rumble. */
const PLOT_MIN_HZ: number = 40;

/** Column buffer, preallocated. No per-frame allocation in the draw path. */
const MAX_COLUMNS: number = 512;

/** Sentinel for "no bin fell in this column" — distinct from a real -90 dB reading. */
const EMPTY: number = -1e9;

@Component
export struct SpectrumCanvas {
  /** Bumped by the page after every analysed frame; @Watch turns that into a redraw. */
  @Prop @Watch('onVersionChanged') version: number = 0;

  /** Shared with the page by reference. Holds the most recent spectrum. */
  store: SpectrumStore = new SpectrumStore();

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;
  private columns: Float64Array = new Float64Array(MAX_COLUMNS);

  onVersionChanged(): void {
    if (this.ready) {
      this.draw();
    }
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.ready = true;
        this.draw();
      });
  }

  private draw(): void {
    const ctx = this.ctx;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }

    ctx.clearRect(0, 0, w, h);

    const padLeft: number = 22;
    const padRight: number = 6;
    const padTop: number = 8;
    const padBottom: number = 18;
    const plotW: number = w - padLeft - padRight;
    const plotH: number = h - padTop - padBottom;
    if (plotW <= 4 || plotH <= 4) {
      return;
    }

    const store = this.store;
    const nyquist: number = store.nyquistHz();
    const fMin: number = Math.max(PLOT_MIN_HZ, store.binWidthHz());
    const fMax: number = Math.max(fMin * 2, nyquist);
    const logMin: number = Math.log10(fMin);
    const logSpan: number = Math.log10(fMax) - logMin;

    this.drawGrid(ctx, padLeft, padTop, plotW, plotH, logMin, logSpan, fMin, fMax);

    if (store.binCount <= 0) {
      ctx.fillStyle = Palette.MUTED;
      ctx.font = `${Type.LABEL}vp sans-serif`;
      ctx.textAlign = 'center';
      ctx.fillText('filling buffer', padLeft + plotW / 2, padTop + plotH / 2);
      return;
    }

    this.reduceToColumns(plotW, logMin, logSpan, fMin, fMax);
    this.drawTrace(ctx, padLeft, padTop, plotW, plotH);
    this.drawPeakMarker(ctx, padLeft, padTop, plotW, plotH, logMin, logSpan, fMin, fMax);
  }

  /**
   * Collapse the bins into one value per pixel column, taking the maximum.
   *
   * Maximum rather than average: a narrow peak spanning one bin out of the forty that
   * share a column at high frequencies would be averaged into invisibility, which is
   * precisely the feature the display exists to show.
   */
  private reduceToColumns(plotW: number, logMin: number, logSpan: number, fMin: number, fMax: number): void {
    const cols: number = Math.min(MAX_COLUMNS, Math.max(1, Math.floor(plotW)));
    const columns = this.columns;
    for (let c: number = 0; c < cols; c++) {
      columns[c] = EMPTY;
    }

    const store = this.store;
    const db = store.decibels;
    for (let k: number = 1; k < store.binCount; k++) {
      const hz: number = store.binToHz(k);
      if (hz < fMin || hz > fMax) {
        continue;
      }
      let c: number = Math.floor((Math.log10(hz) - logMin) / logSpan * cols);
      if (c < 0) {
        c = 0;
      } else if (c >= cols) {
        c = cols - 1;
      }
      if (db[k] > columns[c]) {
        columns[c] = db[k];
      }
    }

    // At the low end, log spacing gives more columns than bins, leaving holes. Carry the
    // last known value forward so the trace stays continuous instead of breaking up into
    // vertical slivers.
    let last: number = DB_FLOOR;
    for (let c: number = 0; c < cols; c++) {
      if (columns[c] === EMPTY) {
        columns[c] = last;
      } else {
        last = columns[c];
      }
    }
  }

  private drawTrace(
    ctx: CanvasRenderingContext2D,
    padLeft: number, padTop: number, plotW: number, plotH: number
  ): void {
    const cols: number = Math.min(MAX_COLUMNS, Math.max(1, Math.floor(plotW)));
    const columns = this.columns;
    const baseline: number = padTop + plotH;

    ctx.beginPath();
    ctx.moveTo(padLeft, baseline);
    for (let c: number = 0; c < cols; c++) {
      const x: number = padLeft + (c / cols) * plotW;
      ctx.lineTo(x, this.dbToY(columns[c], padTop, plotH));
    }
    ctx.lineTo(padLeft + plotW, baseline);
    ctx.closePath();

    ctx.fillStyle = Palette.ACCENT_FILL;
    ctx.fill();

    ctx.beginPath();
    for (let c: number = 0; c < cols; c++) {
      const x: number = padLeft + (c / cols) * plotW;
      const y: number = this.dbToY(columns[c], padTop, plotH);
      if (c === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.strokeStyle = Palette.ACCENT;
    ctx.lineWidth = 1.4;
    ctx.stroke();
  }

  private drawGrid(
    ctx: CanvasRenderingContext2D,
    padLeft: number, padTop: number, plotW: number, plotH: number,
    logMin: number, logSpan: number, fMin: number, fMax: number
  ): void {
    ctx.strokeStyle = Palette.LINE;
    ctx.lineWidth = 0.6;
    ctx.fillStyle = Palette.MUTED;
    ctx.font = `${Type.TINY}vp sans-serif`;

    // dB gridlines
    ctx.textAlign = 'right';
    const levels: number[] = [0, -30, -60, -90];
    for (let i: number = 0; i < levels.length; i++) {
      const y: number = this.dbToY(levels[i], padTop, plotH);
      ctx.beginPath();
      ctx.moveTo(padLeft, y);
      ctx.lineTo(padLeft + plotW, y);
      ctx.stroke();
      ctx.fillText(`${levels[i]}`, padLeft - 3, y + 3);
    }

    // Decade ticks on the log axis
    ctx.textAlign = 'center';
    const decades: number[] = [50, 100, 500, 1000, 5000, 10000];
    for (let i: number = 0; i < decades.length; i++) {
      const hz: number = decades[i];
      if (hz < fMin || hz > fMax) {
        continue;
      }
      const x: number = padLeft + (Math.log10(hz) - logMin) / logSpan * plotW;
      ctx.beginPath();
      ctx.moveTo(x, padTop);
      ctx.lineTo(x, padTop + plotH);
      ctx.stroke();
      const label: string = hz >= 1000 ? `${hz / 1000}k` : `${hz}`;
      ctx.fillText(label, x, padTop + plotH + 11);
    }
  }

  /** The interpolated peak, marked in the one colour reserved for it. */
  private drawPeakMarker(
    ctx: CanvasRenderingContext2D,
    padLeft: number, padTop: number, plotW: number, plotH: number,
    logMin: number, logSpan: number, fMin: number, fMax: number
  ): void {
    const peak = this.store.peak;
    if (peak.binIndex < 0 || peak.frequencyHz < fMin || peak.frequencyHz > fMax) {
      return;
    }

    const x: number = padLeft + (Math.log10(peak.frequencyHz) - logMin) / logSpan * plotW;
    const y: number = this.dbToY(peak.magnitudeDb, padTop, plotH);

    ctx.beginPath();
    ctx.moveTo(x, padTop);
    ctx.lineTo(x, padTop + plotH);
    ctx.strokeStyle = Palette.PEAK;
    ctx.lineWidth = 0.8;
    ctx.stroke();

    ctx.beginPath();
    ctx.arc(x, y, 2.6, 0, Math.PI * 2);
    ctx.fillStyle = Palette.PEAK;
    ctx.fill();
  }

  private dbToY(db: number, padTop: number, plotH: number): number {
    let v: number = db;
    if (v > DB_MAX) {
      v = DB_MAX;
    } else if (v < DB_MIN) {
      v = DB_MIN;
    }
    return padTop + (DB_MAX - v) / (DB_MAX - DB_MIN) * plotH;
  }
}
