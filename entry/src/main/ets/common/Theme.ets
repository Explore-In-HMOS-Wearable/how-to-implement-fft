/*
 * common/Theme.ets — one place for colours and type sizes.
 *
 * Wearable displays are small, often OLED, and usually viewed at a glance. A dark ground
 * keeps the panel dark (OLED pixels that are off draw no power), and the spectrum is the
 * only saturated thing on screen so the eye goes straight to it.
 */

export class Palette {
  static readonly BG: string = '#0B0E14';
  static readonly PANEL: string = '#161B25';
  static readonly TEXT: string = '#E6EAF2';
  static readonly MUTED: string = '#8A93A6';
  static readonly LINE: string = '#232A36';

  /** The spectrum itself — the one saturated colour on screen. */
  static readonly ACCENT: string = '#8E9DFF';
  static readonly ACCENT_FILL: string = '#3A4280';
  static readonly ACCENT_DIM: string = '#4A5480';

  /** Reserved for the interpolated peak marker, and nothing else. */
  static readonly PEAK: string = '#FF8767';

  static readonly GOOD: string = '#4FC28C';
  static readonly WARN: string = '#D9A441';
  static readonly BAD: string = '#FF6B57';
}

export class Type {
  static readonly TITLE: number = 15;
  static readonly BIG: number = 30;
  static readonly BODY: number = 12;
  static readonly LABEL: number = 10;
  static readonly TINY: number = 9;
}

/**
 * Fraction of the round display that is safe for square content.
 *
 * A circular screen clips on distance from the centre, so the largest square that fits
 * inside a circle of diameter d has a side of d/sqrt(2) — about 70%. 76% is slightly
 * generous, which is fine for a plot whose extreme corners are empty background anyway.
 */
export const SAFE_SQUARE: string = '76%';
