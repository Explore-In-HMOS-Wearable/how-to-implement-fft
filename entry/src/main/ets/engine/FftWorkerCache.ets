/*
 * engine/FftWorkerCache.ets — keeps a worker's twiddle tables warm between frames.
 *
 * This file exists because of a concrete ArkTS restriction, and it is worth understanding
 * rather than copying:
 *
 *   An @Concurrent function may only reference IMPORTED variables and LOCAL variables.
 *   A plain module-level `let` in the same file as the concurrent function is neither, and
 *   the build fails with:
 *
 *     10705000 Syntax Error: Concurrent function should only use import variable or
 *     local variable, 'cachedEngine' is not one of them
 *
 * A local variable would be rebuilt on every call, which at N = 4096 means recomputing
 * 2048 cosines and 2048 sines per frame — roughly the cost of the transform itself, and
 * it would make the TaskPool path look far worse than it is for reasons that have nothing
 * to do with threading.
 *
 * So the cache lives in its own module and is reached through an import binding, which
 * the rule does allow. Each taskpool worker loads its own instance of this module, so
 * this is per-worker state, not shared state — no locking, and nothing crosses a thread
 * boundary.
 */

import { FftEngine } from './FftEngine';
import { WindowType } from '../dsp/Window';

class FftWorkerCache {
  engine: FftEngine | undefined = undefined;
  size: number = 0;
  windowType: number = -1;

  /** Returns a ready engine, rebuilding only when the configuration actually changed. */
  acquire(size: number, windowType: number): FftEngine {
    if (this.engine === undefined || this.size !== size || this.windowType !== windowType) {
      this.engine = new FftEngine(size, windowType as WindowType);
      this.size = size;
      this.windowType = windowType;
    }
    return this.engine;
  }
}

export const workerCache: FftWorkerCache = new FftWorkerCache();
