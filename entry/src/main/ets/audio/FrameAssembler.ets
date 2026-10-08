/*
 * audio/FrameAssembler.ets — the bridge between "whatever the system gives you" and
 * "exactly N samples".
 *
 * AudioCapturer's readData callback hands over buffers sized by the audio HAL. That size
 * has no relationship to 4096, it isn't a power of two, and it isn't even guaranteed to
 * be constant between calls. A radix-2 FFT needs exactly a power of two. Something has to
 * reconcile those, and this is it.
 *
 * Design constraints, in priority order:
 *   1. Never allocate after construction. In the steady-state audio path a GC pause is
 *      what turns a smooth spectrum into a stuttering one.
 *   2. Support overlap. Consecutive frames normally share half their samples (hop = N/2)
 *      so the display updates twice as often and transients aren't missed at frame edges.
 *   3. Tolerate any input chunk size, including chunks larger than a whole frame.
 */

export class FrameAssembler {
  readonly frameSize: number;
  readonly hopSize: number;

  /**
   * Circular buffer holding the most recent `frameSize` samples. It only ever needs to be
   * one frame long: once a frame is emitted, the oldest samples are no longer reachable
   * by any future frame, because frames always end at "now".
   */
  private readonly ring: Float64Array;
  /** Reusable output. Handed to the callback; valid only for the duration of that call. */
  private readonly frameOut: Float64Array;

  private writePos: number = 0;
  private filled: number = 0;
  private sinceLastFrame: number = 0;

  /**
   * @param frameSize transform length N — must be a power of two for the FFT downstream
   * @param hopSize   samples between consecutive frames; N/2 gives 50% overlap
   */
  constructor(frameSize: number, hopSize: number) {
    if (frameSize < 2) {
      throw new Error(`FrameAssembler: frameSize must be >= 2, got ${frameSize}`);
    }
    if (hopSize < 1 || hopSize > frameSize) {
      throw new Error(
        `FrameAssembler: hopSize must be in [1, ${frameSize}], got ${hopSize}`
      );
    }

    this.frameSize = frameSize;
    this.hopSize = hopSize;
    this.ring = new Float64Array(frameSize);
    this.frameOut = new Float64Array(frameSize);
  }

  /** Drop all buffered history. Call when the source changes. */
  reset(): void {
    this.ring.fill(0);
    this.writePos = 0;
    this.filled = 0;
    this.sinceLastFrame = 0;
  }

  /** How full the buffer is, 0..1 — drives the "filling buffer" state in the UI. */
  fillRatio(): number {
    return this.filled / this.frameSize;
  }

  /**
   * Feed interleaved 16-bit little-endian PCM, as delivered by AudioCapturer.
   *
   * Signed 16-bit divides by 32768 rather than 32767: the format is asymmetric
   * (-32768..32767), and 32768 is the value that maps the range to [-1, 1) without
   * clipping the negative extreme.
   *
   * Mono is assumed. With more channels this would need to deinterleave or downmix first.
   */
  pushInt16(buffer: ArrayBuffer, onFrame: (frame: Float64Array) => void): void {
    const src = new Int16Array(buffer);
    for (let i: number = 0; i < src.length; i++) {
      this.pushSample(src[i] / 32768, onFrame);
    }
  }

  /** Feed already-normalized float samples, as produced by SignalGenerator. */
  pushFloat(samples: Float64Array, count: number, onFrame: (frame: Float64Array) => void): void {
    const n: number = Math.min(count, samples.length);
    for (let i: number = 0; i < n; i++) {
      this.pushSample(samples[i], onFrame);
    }
  }

  private pushSample(value: number, onFrame: (frame: Float64Array) => void): void {
    const n: number = this.frameSize;

    this.ring[this.writePos] = value;
    this.writePos = this.writePos + 1;
    if (this.writePos === n) {
      this.writePos = 0;
    }
    if (this.filled < n) {
      this.filled++;
    }
    this.sinceLastFrame++;

    // A frame is due once the buffer holds a full frame AND a full hop of new samples
    // has arrived since the last one.
    if (this.filled === n && this.sinceLastFrame >= this.hopSize) {
      this.sinceLastFrame = 0;
      this.copyOut();
      onFrame(this.frameOut);
    }
  }

  /**
   * Unwrap the ring into chronological order. writePos is where the next sample goes,
   * which is also the position of the oldest sample still held.
   */
  private copyOut(): void {
    const n: number = this.frameSize;
    const ring = this.ring;
    const out = this.frameOut;
    const start: number = this.writePos;

    const head: number = n - start;
    for (let i: number = 0; i < head; i++) {
      out[i] = ring[start + i];
    }
    for (let i: number = 0; i < start; i++) {
      out[head + i] = ring[i];
    }
  }
}
