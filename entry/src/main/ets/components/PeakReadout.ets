/*
 * components/PeakReadout.ets — the dominant frequency, and the numbers that qualify it.
 *
 * The bin index and bin width are shown next to the frequency on purpose. A reading of
 * "440.02 Hz" from a transform whose bins are 10.77 Hz apart looks like false precision
 * until you can see that it came from bin 41 plus interpolation. Showing both makes the
 * claim checkable instead of magical.
 */

import { SpectrumStore } from '../common/SpectrumStore';
import { Palette, Type } from '../common/Theme';
import { formatDb, formatHz, frequencyToNote, NoteName } from '../common/Format';
import { PeakEstimate, DB_FLOOR } from '../dsp/Spectrum';

@Component
export struct PeakReadout {
  /**
   * Bumped by the page after every analysed frame.
   *
   * The @Watch is what makes this work, and it is not optional. ArkUI registers a redraw
   * dependency on the state a build() actually READS, and nothing below reads `version` —
   * every displayed number comes from `store`, which is deliberately not @Observed. A
   * bare @Prop would therefore be written every frame and repaint nothing. The watcher
   * fires on assignment instead, and copies the peak into @State, which build() does read.
   */
  @Prop @Watch('onVersionChanged') version: number = 0;
  /** Expected peak from the synthetic generator, or 0 when there isn't a known answer. */
  @Prop expectedHz: number = 0;
  @Prop statusText: string = '';

  store: SpectrumStore = new SpectrumStore();

  /** The store's peak, mirrored where ArkUI can see it change. */
  @State private peak: PeakEstimate = {
    binIndex: -1, binHz: 0, frequencyHz: 0, magnitudeDb: DB_FLOOR, binOffset: 0
  };

  onVersionChanged(): void {
    // findPeak returns a fresh object per frame, so the reference always differs and the
    // assignment is never elided.
    this.peak = this.store.peak;
  }

  build() {
    Column({ space: 2 }) {
      Text('DOMINANT PEAK')
        .fontSize(Type.TINY)
        .fontColor(Palette.MUTED)
        .letterSpacing(1.2);

      Text(this.peakLabel())
        .fontSize(Type.BIG)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.peak.binIndex >= 0 ? Palette.TEXT : Palette.MUTED);

      Text(this.noteLabel())
        .fontSize(Type.BODY)
        .fontColor(Palette.ACCENT)
        .margin({ bottom: 6 });

      this.row('bin', this.binLabel());
      this.row('level', formatDb(this.peak.magnitudeDb));
      this.row('resolution', `${this.store.binWidthHz().toFixed(2)} Hz/bin`);

      if (this.expectedHz > 0) {
        this.row('expected', formatHz(this.expectedHz));
        this.row('error', this.errorLabel());
      }

      Text(this.statusText)
        .fontSize(Type.TINY)
        .fontColor(Palette.MUTED)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .margin({ top: 6 });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  row(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(Type.LABEL)
        .fontColor(Palette.MUTED);
      Blank();
      Text(value)
        .fontSize(Type.LABEL)
        .fontColor(Palette.TEXT);
    }
    .width('86%')
    .padding({ top: 1, bottom: 1 });
  }

  private peakLabel(): string {
    const peak = this.peak;
    return peak.binIndex >= 0 ? formatHz(peak.frequencyHz) : '-- Hz';
  }

  private noteLabel(): string {
    const peak = this.peak;
    if (peak.binIndex < 0) {
      return 'no signal';
    }
    const note: NoteName = frequencyToNote(peak.frequencyHz);
    if (note.label === '') {
      return 'out of musical range';
    }
    const sign: string = note.cents > 0 ? '+' : '';
    return `${note.label}  ${sign}${note.cents} cents`;
  }

  /** "41 +0.13" — the raw bin and the sub-bin offset interpolation added to it. */
  private binLabel(): string {
    const peak = this.peak;
    if (peak.binIndex < 0) {
      return '--';
    }
    const sign: string = peak.binOffset >= 0 ? '+' : '';
    return `${peak.binIndex} ${sign}${peak.binOffset.toFixed(2)}`;
  }

  private errorLabel(): string {
    const peak = this.peak;
    if (peak.binIndex < 0 || this.expectedHz <= 0) {
      return '--';
    }
    const errHz: number = peak.frequencyHz - this.expectedHz;
    const sign: string = errHz >= 0 ? '+' : '';
    return `${sign}${errHz.toFixed(2)} Hz`;
  }
}
