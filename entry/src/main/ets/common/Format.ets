/*
 * common/Format.ets — display formatting.
 *
 * Note naming lives here rather than in dsp/ because it is presentation, not signal
 * processing. The FFT has no opinion about musical notes.
 */

const NOTE_NAMES: string[] = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const A4_HZ: number = 440;

export interface NoteName {
  /** e.g. "A4". Empty when the frequency is out of musical range. */
  label: string;
  /** Deviation from the nearest equal-tempered semitone, in cents. */
  cents: number;
}

export function formatHz(hz: number): string {
  if (hz <= 0) {
    return '--';
  }
  if (hz >= 1000) {
    return `${(hz / 1000).toFixed(2)} kHz`;
  }
  if (hz >= 100) {
    return `${hz.toFixed(1)} Hz`;
  }
  return `${hz.toFixed(2)} Hz`;
}

export function formatDb(db: number): string {
  if (db <= -119) {
    return '-- dB';
  }
  return `${db.toFixed(1)} dB`;
}

export function formatMs(ms: number): string {
  if (ms < 10) {
    return `${ms.toFixed(2)} ms`;
  }
  return `${ms.toFixed(1)} ms`;
}

/**
 * Nearest equal-tempered note, plus how far off it is.
 *
 * Present as a sanity check on the peak estimate, not as a tuning feature — cents only
 * mean anything here because Spectrum.findPeak interpolates. Straight off the peak bin,
 * a 10.77 Hz error at A4 would be about 42 cents, which is nearly half a semitone.
 */
export function frequencyToNote(hz: number): NoteName {
  if (hz < 16 || hz > 8000) {
    const none: NoteName = { label: '', cents: 0 };
    return none;
  }

  const semitonesFromA4: number = 12 * Math.log2(hz / A4_HZ);
  const nearest: number = Math.round(semitonesFromA4);
  const cents: number = Math.round((semitonesFromA4 - nearest) * 100);

  // A4 is MIDI 69; C-1 is MIDI 0.
  const midi: number = nearest + 69;
  const name: string = NOTE_NAMES[((midi % 12) + 12) % 12];
  const octave: number = Math.floor(midi / 12) - 1;

  const note: NoteName = { label: `${name}${octave}`, cents: cents };
  return note;
}
