/*
 * common/Clock.ets — a monotonic clock with sub-millisecond resolution.
 *
 * Date.now() is useless for this codelab: it resolves to 1 ms, and a 4096-point FFT is
 * expected to take single-digit milliseconds, so every measurement would read 0, 1 or 2.
 * systemDateTime.getUptime(ACTIVE, true) returns nanoseconds and is monotonic, which is
 * what a benchmark needs.
 */

import { systemDateTime } from '@kit.BasicServicesKit';

/** Resolved once at startup so the hot path has no try/catch and no repeated probing. */
const HAS_NANO_CLOCK: boolean = probeNanoClock();

function probeNanoClock(): boolean {
  try {
    const t: number = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true);
    return t > 0;
  } catch (err) {
    return false;
  }
}

/** Monotonic milliseconds, fractional where the platform allows it. */
export function nowMs(): number {
  if (HAS_NANO_CLOCK) {
    return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1e6;
  }
  return Date.now();
}

/** True when timings are finer than 1 ms — reported on the Diagnostics page. */
export function hasHighResolutionClock(): boolean {
  return HAS_NANO_CLOCK;
}
