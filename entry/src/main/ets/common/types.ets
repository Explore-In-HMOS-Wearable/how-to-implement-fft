/*
 * common/types.ets — app-level types.
 *
 * Imports from dsp/ (one direction only — dsp/ never imports from here, which is what
 * keeps that folder portable).
 */

import { WindowType } from '../dsp/Window';

/** Where the samples come from. */
export enum SourceKind {
  SYNTHETIC = 0,   // generated in-app: works on any device, no permission, known answer
  MICROPHONE = 1   // live capture via AudioCapturer
}

/** Which synthetic waveform the generator produces. */
export enum SignalKind {
  SINE = 0,
  TWO_TONE = 1,
  HARMONIC = 2,
  CHIRP = 3,
  NOISE = 4
}

/** Where the transform runs. See README §"Main thread or TaskPool". */
export enum EngineMode {
  MAIN_THREAD = 0,
  TASK_POOL = 1
}

export const SIGNAL_KINDS: SignalKind[] = [
  SignalKind.SINE,
  SignalKind.TWO_TONE,
  SignalKind.HARMONIC,
  SignalKind.CHIRP,
  SignalKind.NOISE
];

export function signalKindName(kind: SignalKind): string {
  switch (kind) {
    case SignalKind.SINE: return 'Sine';
    case SignalKind.TWO_TONE: return 'Two tone';
    case SignalKind.HARMONIC: return 'Harmonics';
    case SignalKind.CHIRP: return 'Chirp';
    case SignalKind.NOISE: return 'White noise';
    default: return 'Unknown';
  }
}

export function sourceKindName(kind: SourceKind): string {
  return kind === SourceKind.MICROPHONE ? 'Microphone' : 'Synthetic';
}

export function engineModeName(mode: EngineMode): string {
  return mode === EngineMode.TASK_POOL ? 'TaskPool' : 'Main thread';
}

/** Everything that decides how a frame is analysed. */
export interface FftConfig {
  fftSize: number;
  hopSize: number;
  sampleRate: number;
  windowType: WindowType;
  engineMode: EngineMode;
}

/** Rolling performance numbers shown on the Diagnostics page. */
export interface EngineStats {
  lastMs: number;
  averageMs: number;
  maxMs: number;
  framesPerSecond: number;
  framesAnalysed: number;
  framesDropped: number;
}

/** Search range for the dominant peak. Below 40 Hz is mostly DC offset and rumble. */
export const PEAK_MIN_HZ: number = 40;
