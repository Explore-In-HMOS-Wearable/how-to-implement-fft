/*
 * components/ControlsPanel.ets — every knob, on an ArcList.
 *
 * ArcList rather than List: on a round display a plain List's first and last rows sit
 * near the poles, where the bezel clips them into slivers. ArcList insets each row by its
 * distance from the centre, so rows stay readable all the way to the edge.
 *
 * Every row is a tap-to-cycle control. A watch has no room for dropdowns, and cycling
 * keeps the whole state visible: the current value is always the thing on screen.
 */

import { ArcList, ArcListAttribute, ArcListItem, ArcListItemAttribute } from '@kit.ArkUI';
import { Palette, Type } from '../common/Theme';
import { SUPPORTED_SIZES } from '../dsp/Fft';
import { WindowType, WINDOW_TYPES, windowTypeName } from '../dsp/Window';
import {
  EngineMode, engineModeName, SignalKind, SIGNAL_KINDS, signalKindName, SourceKind, sourceKindName
} from '../common/types';

/** Tap-to-cycle frequencies — two octaves either side of concert A. */
const TEST_FREQUENCIES: number[] = [110, 220, 440, 880, 1760];

/** hop = N / divisor. 1 is no overlap, 4 is 75%. */
const HOP_DIVISORS: number[] = [1, 2, 4];

@Component
export struct ControlsPanel {
  @Prop running: boolean = false;
  @Prop sourceKind: number = SourceKind.SYNTHETIC;
  @Prop signalKind: number = SignalKind.SINE;
  @Prop signalHz: number = 440;
  @Prop fftSize: number = 4096;
  @Prop windowType: number = WindowType.HANN;
  @Prop hopDivisor: number = 2;
  @Prop engineMode: number = EngineMode.MAIN_THREAD;

  onToggleRun: () => void = () => {};
  onSourceChange: (kind: SourceKind) => void = () => {};
  onSignalChange: (kind: SignalKind) => void = () => {};
  onFrequencyChange: (hz: number) => void = () => {};
  // NOT onSizeChange — CustomComponent already declares that as a layout callback, and a
  // clashing name fails the build with a confusing type error about SizeChangeCallback.
  onFrameSizeChange: (size: number) => void = () => {};
  onWindowChange: (type: WindowType) => void = () => {};
  onHopChange: (divisor: number) => void = () => {};
  onEngineChange: (mode: EngineMode) => void = () => {};

  build() {
    ArcList({ initialIndex: 0 }) {
      ArcListItem() {
        Button(this.running ? 'Stop' : 'Start')
          .fontSize(Type.BODY)
          .width('70%')
          .height(32)
          .backgroundColor(this.running ? Palette.BAD : Palette.GOOD)
          .fontColor(Palette.BG)
          .onClick(() => this.onToggleRun());
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.settingRow('Source', sourceKindName(this.sourceKind as SourceKind), () => {
          const next: SourceKind = this.sourceKind === SourceKind.SYNTHETIC
            ? SourceKind.MICROPHONE
            : SourceKind.SYNTHETIC;
          this.onSourceChange(next);
        });
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.settingRow('Signal', signalKindName(this.signalKind as SignalKind), () => {
          this.onSignalChange(cycle(SIGNAL_KINDS, this.signalKind as SignalKind));
        });
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.settingRow('Tone', `${this.signalHz} Hz`, () => {
          this.onFrequencyChange(cycleNumber(TEST_FREQUENCIES, this.signalHz));
        });
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.settingRow('Frame N', `${this.fftSize}`, () => {
          this.onFrameSizeChange(cycleNumber(SUPPORTED_SIZES, this.fftSize));
        });
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.settingRow('Window', windowTypeName(this.windowType as WindowType), () => {
          this.onWindowChange(cycle(WINDOW_TYPES, this.windowType as WindowType));
        });
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.settingRow('Overlap', overlapLabel(this.hopDivisor), () => {
          this.onHopChange(cycleNumber(HOP_DIVISORS, this.hopDivisor));
        });
      }
      .align(Alignment.Center);

      ArcListItem() {
        this.settingRow('Engine', engineModeName(this.engineMode as EngineMode), () => {
          const next: EngineMode = this.engineMode === EngineMode.MAIN_THREAD
            ? EngineMode.TASK_POOL
            : EngineMode.MAIN_THREAD;
          this.onEngineChange(next);
        });
      }
      .align(Alignment.Center);
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  settingRow(label: string, value: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(Type.LABEL)
        .fontColor(Palette.MUTED);
      Blank();
      Text(value)
        .fontSize(Type.BODY)
        .fontColor(Palette.ACCENT);
    }
    .width('78%')
    .height(30)
    .padding({ left: 10, right: 10 })
    .borderRadius(15)
    .backgroundColor(Palette.PANEL)
    .onClick(onTap);
  }
}

/** Next value in the list, wrapping. Falls back to the first entry if `current` is absent. */
function cycle<T>(values: T[], current: T): T {
  const index: number = values.indexOf(current);
  return values[(index + 1) % values.length];
}

function cycleNumber(values: number[], current: number): number {
  const index: number = values.indexOf(current);
  return values[(index + 1) % values.length];
}

function overlapLabel(divisor: number): string {
  if (divisor <= 1) {
    return 'none';
  }
  return `${Math.round((1 - 1 / divisor) * 100)}%`;
}
