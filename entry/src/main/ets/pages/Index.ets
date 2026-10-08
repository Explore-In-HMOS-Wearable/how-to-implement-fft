/*
 * pages/Index.ets — four full-bleed pages on a Swiper.
 *
 * Why a Swiper of full-screen pages rather than one scrolling layout: a round display
 * clips on distance from the centre in BOTH axes, so stacking "plot on top, controls
 * below" pushes content toward the poles where the bezel cuts it into slivers. Giving
 * each concern the whole screen keeps everything inside the readable disc.
 *
 * The page owns the @State that ArkUI observes. AnalyzerController deliberately isn't
 * @Observed — its payload is a Float64Array whose contents change while its reference
 * doesn't, which ArkUI cannot see — so updates arrive via callback, land in SpectrumStore,
 * and a version counter tells the components to redraw.
 */

import { common } from '@kit.AbilityKit';
import { AnalyzerController, AnalysisUpdate } from '../engine/AnalyzerController';
import { SpectrumStore } from '../common/SpectrumStore';
import { Palette, SAFE_SQUARE, Type } from '../common/Theme';
import { formatHz } from '../common/Format';
import { WindowType } from '../dsp/Window';
import { EngineMode, engineModeName, SignalKind, SourceKind } from '../common/types';
import { SpectrumCanvas } from '../components/SpectrumCanvas';
import { PeakReadout } from '../components/PeakReadout';
import { ControlsPanel } from '../components/ControlsPanel';
import { DiagnosticsPanel } from '../components/DiagnosticsPanel';

@Entry
@Component
struct Index {
  /** Incremented after every analysed frame. The only thing that drives redraws. */
  @State version: number = 0;

  // Mirrors of the controller's configuration, so the UI can render it.
  @State running: boolean = false;
  @State sourceKind: number = SourceKind.SYNTHETIC;
  @State signalKind: number = SignalKind.SINE;
  @State signalHz: number = 440;
  @State fftSize: number = 4096;
  @State windowType: number = WindowType.HANN;
  @State hopDivisor: number = 2;
  @State engineMode: number = EngineMode.MAIN_THREAD;
  @State statusText: string = '';
  @State expectedHz: number = 440;

  private controller: AnalyzerController = new AnalyzerController();
  private store: SpectrumStore = new SpectrumStore();
  private context: common.UIAbilityContext =
    this.getUIContext().getHostContext() as common.UIAbilityContext;

  async aboutToAppear(): Promise<void> {
    this.controller.setOnUpdate((update: AnalysisUpdate) => {
      this.store.update(update);
      this.version++;
    });
    await this.controller.start(this.context);
    this.syncFromController();
  }

  async aboutToDisappear(): Promise<void> {
    await this.controller.stop();
  }

  build() {
    Stack() {
      Swiper() {
        this.spectrumPage();
        this.readoutPage();
        this.controlsPage();
        this.diagnosticsPage();
      }
      .loop(false)
      .indicator(
        new DotIndicator()
          .color(Palette.LINE)
          .selectedColor(Palette.ACCENT)
          .itemWidth(4)
          .itemHeight(4)
          .selectedItemWidth(4)
          .selectedItemHeight(4)
      )
      .width('100%')
      .height('100%');
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG);
  }

  // ---------------------------------------------------------------- pages

  @Builder
  spectrumPage() {
    Column({ space: 4 }) {
      Text(`N=${this.fftSize}  ${this.sampleRateLabel()}`)
        .fontSize(Type.TINY)
        .fontColor(Palette.MUTED);

      SpectrumCanvas({ version: this.version, store: this.store })
        .width(SAFE_SQUARE)
        .height('46%');

      Text(this.store.peak.binIndex >= 0 ? formatHz(this.store.peak.frequencyHz) : '-- Hz')
        .fontSize(Type.TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT);

      Text('Hz (log)  ·  dBFS')
        .fontSize(Type.TINY)
        .fontColor(Palette.MUTED);
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  readoutPage() {
    Column() {
      PeakReadout({
        version: this.version,
        expectedHz: this.expectedHz,
        statusText: this.statusText,
        store: this.store
      });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  controlsPage() {
    ControlsPanel({
      running: this.running,
      sourceKind: this.sourceKind,
      signalKind: this.signalKind,
      signalHz: this.signalHz,
      fftSize: this.fftSize,
      windowType: this.windowType,
      hopDivisor: this.hopDivisor,
      engineMode: this.engineMode,
      onToggleRun: () => this.toggleRun(),
      onSourceChange: (kind: SourceKind) => this.changeSource(kind),
      onSignalChange: (kind: SignalKind) => this.changeSignal(kind),
      onFrequencyChange: (hz: number) => this.changeFrequency(hz),
      onFrameSizeChange: (size: number) => this.changeSize(size),
      onWindowChange: (type: WindowType) => this.changeWindow(type),
      onHopChange: (divisor: number) => this.changeHop(divisor),
      onEngineChange: (mode: EngineMode) => this.changeEngine(mode)
    });
  }

  @Builder
  diagnosticsPage() {
    DiagnosticsPanel({
      version: this.version,
      engineLabel: engineModeName(this.engineMode as EngineMode),
      store: this.store
    });
  }

  // ---------------------------------------------------------------- handlers

  private syncFromController(): void {
    this.running = this.controller.isRunning();
    this.sourceKind = this.controller.getSourceKind();
    this.signalKind = this.controller.getSignalKind();
    this.signalHz = this.controller.getSignalFrequency();
    this.fftSize = this.controller.getFftSize();
    this.windowType = this.controller.getWindowType();
    this.hopDivisor = this.controller.getHopDivisor();
    this.engineMode = this.controller.getEngineMode();
    this.statusText = this.controller.getStatus();
    this.expectedHz = this.controller.expectedPeakHz();
  }

  private async toggleRun(): Promise<void> {
    if (this.controller.isRunning()) {
      await this.controller.stop();
    } else {
      await this.controller.start(this.context);
    }
    this.syncFromController();
  }

  /** Source, N and hop all change how frames are produced, so they need a restart. */
  private async changeSource(kind: SourceKind): Promise<void> {
    this.controller.setSourceKind(kind);
    await this.controller.restart(this.context);
    this.syncFromController();
  }

  private async changeSize(size: number): Promise<void> {
    this.controller.setFftSize(size);
    await this.controller.restart(this.context);
    this.syncFromController();
  }

  private async changeHop(divisor: number): Promise<void> {
    this.controller.setHopDivisor(divisor);
    await this.controller.restart(this.context);
    this.syncFromController();
  }

  // These take effect on the next frame with no restart needed.
  private changeSignal(kind: SignalKind): void {
    this.controller.setSignalKind(kind);
    this.syncFromController();
  }

  private changeFrequency(hz: number): void {
    this.controller.setSignalFrequency(hz);
    this.syncFromController();
  }

  private changeWindow(type: WindowType): void {
    this.controller.setWindowType(type);
    this.syncFromController();
  }

  private changeEngine(mode: EngineMode): void {
    this.controller.setEngineMode(mode);
    this.syncFromController();
  }

  private sampleRateLabel(): string {
    const rate: number = this.controller.getSampleRate();
    return `${(rate / 1000).toFixed(1)}k`;
  }
}
