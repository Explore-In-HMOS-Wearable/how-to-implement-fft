/*
 * engine/FftTask.ets — the same analysis, run off the UI thread.
 *
 * At N = 4096 and hop 2048 the frame budget is about 46 ms and the transform takes single
 * -digit milliseconds, so the main thread is probably fine. "Probably" is not an
 * engineering answer, which is why both paths exist and the Diagnostics page reports
 * measured numbers for each.
 *
 * TaskPool is not free, and the costs are worth naming because they are the reason the
 * result is not a foregone conclusion:
 *
 *   - Dispatch overhead per frame, paid whether the transform takes 1 ms or 20 ms.
 *   - A copy into a transferable buffer on the way in, and a copy out of the engine's
 *     spectrum on the way back.
 *   - A cold worker on the first frame (see FftWorkerCache for what keeps it warm, and
 *     for the ArkTS rule that dictates how).
 *
 * For small N these can exceed the transform itself, making TASK_POOL slower than
 * MAIN_THREAD. That is a real result, not a bug.
 */

import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FftEngine } from './FftEngine';
import { workerCache } from './FftWorkerCache';
import { WindowType } from '../dsp/Window';

const DOMAIN: number = 0x0000;
const TAG: string = 'FftTask';

/**
 * Runs on a taskpool worker. Takes a frame of Float64 samples as a transferable
 * ArrayBuffer and returns the dBFS spectrum as another one.
 *
 * ArrayBuffers are transferred rather than structurally cloned, so a 32 KB frame crosses
 * the thread boundary without being duplicated.
 *
 * Note what this function is allowed to touch: `workerCache` is an import binding and
 * everything else is local. A module-level `let` in this file would fail the build — see
 * FftWorkerCache for the full explanation.
 */
@Concurrent
function analyzeOnWorker(frameBuffer: ArrayBuffer, fftSize: number, windowType: number): ArrayBuffer {
  const engine: FftEngine = workerCache.acquire(fftSize, windowType);
  engine.analyze(new Float64Array(frameBuffer));

  // Copy out: the engine reuses its spectrum buffer for the next frame, so the result has
  // to be a detached array we can hand back.
  return engine.spectrum.decibels.slice().buffer;
}

/**
 * Main-thread side of the TaskPool path.
 *
 * Deliberately drops frames rather than queueing them. If the worker cannot keep up,
 * queueing would grow an unbounded backlog and the display would fall further and further
 * behind live audio. Dropping keeps the spectrum current and makes overload visible as a
 * dropped-frame count instead of hiding it as latency.
 */
export class TaskPoolAnalyzer {
  private inFlight: boolean = false;
  private dropped: number = 0;

  /** Frames skipped because a previous one was still being transformed. */
  get droppedFrames(): number {
    return this.dropped;
  }

  resetCounters(): void {
    this.dropped = 0;
  }

  /**
   * Dispatch one frame. Resolves with the dBFS spectrum, or undefined when the frame was
   * dropped because the pool was busy, or when dispatch failed.
   *
   * `frame` is copied here — it belongs to FrameAssembler, which will overwrite it on the
   * next hop, and the copy is what gets transferred to the worker.
   */
  async analyze(
    frame: Float64Array,
    fftSize: number,
    windowType: WindowType
  ): Promise<Float64Array | undefined> {
    if (this.inFlight) {
      this.dropped++;
      return undefined;
    }
    this.inFlight = true;

    try {
      const payload = new Float64Array(fftSize);
      payload.set(frame.subarray(0, fftSize));

      const task: taskpool.Task = new taskpool.Task(
        analyzeOnWorker, payload.buffer, fftSize, windowType as number
      );
      task.setTransferList([payload.buffer]);

      const raw: Object = await taskpool.execute(task);
      return new Float64Array(raw as ArrayBuffer);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'TaskPool dispatch failed: %{public}s', e.message);
      return undefined;
    } finally {
      this.inFlight = false;
    }
  }
}
