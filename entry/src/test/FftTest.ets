/*
 * entry/src/test/FftTest.ets — the dsp/ self-test assertions as hypium local unit tests.
 *
 * The same checks run on-device from the Diagnostics page. They are duplicated here so a
 * regression fails the build rather than waiting to be noticed on a watch face.
 */

import { describe, it, expect } from '@ohos/hypium';
import { Fft, isPowerOfTwo, log2Exact, SUPPORTED_SIZES } from '../main/ets/dsp/Fft';
import { FftSelfTest, SelfTestReport, SelfTestResult } from '../main/ets/dsp/FftSelfTest';
import { Spectrum } from '../main/ets/dsp/Spectrum';
import { WindowFunction, WindowType } from '../main/ets/dsp/Window';
import { FrameAssembler } from '../main/ets/audio/FrameAssembler';

export default function fftTest() {

  describe('FftSelfTest', () => {
    // Every supported frame size, not just the default — a bug in the bit-reversal or a
    // twiddle stride can easily show up at one N and not another.
    SUPPORTED_SIZES.forEach((size: number) => {
      it(`selfTest_N${size}`, 0, () => {
        const report: SelfTestReport = FftSelfTest.runAll(size);
        report.results.forEach((r: SelfTestResult) => {
          // Assert per-check so a failure names the property that broke, not just a count.
          expect(`${r.name}: ${r.passed} (${r.detail})`)
            .assertEqual(`${r.name}: true (${r.detail})`);
        });
        expect(report.failed).assertEqual(0);
      });
    });
  });

  describe('FftGuards', () => {
    it('rejectsNonPowerOfTwo', 0, () => {
      expect(isPowerOfTwo(4096)).assertTrue();
      expect(isPowerOfTwo(4095)).assertFalse();
      expect(isPowerOfTwo(1)).assertFalse();

      let threw: boolean = false;
      try {
        const bad = new Fft(1000);
        expect(bad.size).assertEqual(1000);
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('log2IsExact', 0, () => {
      expect(log2Exact(256)).assertEqual(8);
      expect(log2Exact(4096)).assertEqual(12);
    });

    it('rejectsWrongBufferLength', 0, () => {
      const fft = new Fft(256);
      let threw: boolean = false;
      try {
        fft.forward(new Float64Array(128), new Float64Array(256));
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
    });
  });

  describe('WindowFunction', () => {
    it('coherentGainMatchesKnownValues', 0, () => {
      // Textbook values. Computed from the coefficient array, so this catches a typo in
      // any window formula as well as a broken gain calculation.
      const size: number = 1024;
      expect(Math.abs(new WindowFunction(WindowType.RECTANGULAR, size).coherentGain - 1.0) < 1e-12)
        .assertTrue();
      expect(Math.abs(new WindowFunction(WindowType.HANN, size).coherentGain - 0.5) < 1e-12)
        .assertTrue();
      expect(Math.abs(new WindowFunction(WindowType.HAMMING, size).coherentGain - 0.54) < 1e-12)
        .assertTrue();
      expect(Math.abs(new WindowFunction(WindowType.BLACKMAN, size).coherentGain - 0.42) < 1e-12)
        .assertTrue();
    });

    it('tapersToZeroAtEdges', 0, () => {
      const hann = new WindowFunction(WindowType.HANN, 512);
      expect(Math.abs(hann.coefficients[0]) < 1e-12).assertTrue();
    });
  });

  describe('SpectrumScaling', () => {
    it('recoversAmplitudeUnderEveryWindow', 0, () => {
      // The whole point of coherent-gain correction: a 0.25-amplitude sine must read
      // -12.04 dBFS regardless of which window was applied.
      const size: number = 2048;
      const bin: number = 256;
      const amplitude: number = 0.25;
      const windows: WindowType[] =
        [WindowType.RECTANGULAR, WindowType.HANN, WindowType.HAMMING, WindowType.BLACKMAN];

      windows.forEach((type: WindowType) => {
        const fft = new Fft(size);
        const win = new WindowFunction(type, size);
        const spectrum = new Spectrum(size);
        const samples = new Float64Array(size);
        const re = new Float64Array(size);
        const im = new Float64Array(size);

        for (let n: number = 0; n < size; n++) {
          samples[n] = amplitude * Math.cos(6.283185307179586 * bin * n / size);
        }
        win.apply(samples, samples);
        fft.forwardReal(samples, re, im);
        spectrum.compute(re, im, win.coherentGain);

        const recovered: number = Math.pow(10, spectrum.decibels[bin] / 20);
        expect(Math.abs(recovered - amplitude) < 1e-9).assertTrue();
      });
    });

    it('binWidthMatchesSampleRate', 0, () => {
      const spectrum = new Spectrum(4096);
      // 44100 / 4096 = 10.7666... Hz — the resolution figure quoted throughout the README.
      expect(Math.abs(spectrum.binWidthHz(44100) - 10.7666015625) < 1e-9).assertTrue();
      expect(spectrum.binCount).assertEqual(2049);
    });
  });

  describe('FrameAssembler', () => {
    it('emitsFixedFramesFromRaggedChunks', 0, () => {
      // The reason this class exists: readData chunk sizes have no relationship to N.
      const frameSize: number = 256;
      const assembler = new FrameAssembler(frameSize, frameSize / 2);
      const chunkSizes: number[] = [37, 200, 5, 411, 64, 99];

      let frames: number = 0;
      let wrongLength: number = 0;
      let counter: number = 0;

      chunkSizes.forEach((chunk: number) => {
        const block = new Float64Array(chunk);
        for (let i: number = 0; i < chunk; i++) {
          block[i] = counter++;
        }
        assembler.pushFloat(block, chunk, (frame: Float64Array) => {
          frames++;
          if (frame.length !== frameSize) {
            wrongLength++;
          }
        });
      });

      const total: number = 37 + 200 + 5 + 411 + 64 + 99;   // 816 samples
      // First frame at 256, then one per 128-sample hop: 1 + floor((816-256)/128) = 5.
      expect(frames).assertEqual(5);
      expect(wrongLength).assertEqual(0);
    });

    it('preservesSampleOrderAcrossTheRingWrap', 0, () => {
      // A ring buffer that unwraps incorrectly still produces plausible-looking frames,
      // so check the actual contents: the frame must be the last N samples, in order.
      const frameSize: number = 64;
      const assembler = new FrameAssembler(frameSize, frameSize);
      const block = new Float64Array(200);
      for (let i: number = 0; i < 200; i++) {
        block[i] = i;
      }

      const seen: number[] = [];
      assembler.pushFloat(block, 200, (frame: Float64Array) => {
        seen.push(frame[0]);
        // Contiguous and ascending: frame[j] must be frame[0] + j.
        for (let j: number = 0; j < frameSize; j++) {
          expect(frame[j]).assertEqual(frame[0] + j);
        }
      });

      expect(seen.length).assertEqual(3);
      expect(seen[0]).assertEqual(0);
      expect(seen[1]).assertEqual(64);
      expect(seen[2]).assertEqual(128);
    });

    it('normalizesInt16ToUnitRange', 0, () => {
      const frameSize: number = 8;
      const assembler = new FrameAssembler(frameSize, frameSize);
      // Built over an explicit ArrayBuffer: Int16Array.buffer is typed ArrayBufferLike,
      // and handing that to a parameter declared ArrayBuffer trips
      // arkts-no-structural-typing.
      const raw: ArrayBuffer = new ArrayBuffer(frameSize * 2);
      const pcm = new Int16Array(raw);
      pcm[0] = -32768;
      pcm[1] = 32767;

      // Collected into an array rather than a `Float64Array | undefined` local: ArkTS
      // does not narrow a captured union across a callback boundary, and casting it back
      // trips arkts-no-structural-typing.
      const captured: Float64Array[] = [];
      assembler.pushInt16(raw, (frame: Float64Array) => {
        captured.push(frame.slice());
      });

      expect(captured.length).assertEqual(1);
      const frame: Float64Array = captured[0];
      expect(frame[0]).assertEqual(-1);                     // exactly -1.0, no clipping
      expect(frame[1] < 1 && frame[1] > 0.9999).assertTrue();
    });
  });
}
