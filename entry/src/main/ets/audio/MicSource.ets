/*
 * audio/MicSource.ets — live PCM from the watch microphone.
 *
 * Follows the AudioCapturer pattern used by the guitar-tuner sample, with two differences that
 * matter for an FFT:
 *
 *   1. The sample rate is negotiated, not assumed. Not every wearable supports 44.1 kHz;
 *      16 kHz is the common fallback. Every bin-to-hertz conversion downstream depends on
 *      knowing which one you actually got, so the rate is read back and published rather
 *      than hard-coded.
 *   2. Buffers are handed straight to FrameAssembler instead of being analysed directly,
 *      because readData's chunk size is whatever the audio HAL chose and a radix-2 FFT
 *      needs exactly a power of two.
 */

import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'MicSource';

const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';

/** Preferred first, fallback second. */
const CANDIDATE_RATES: number[] = [44100, 16000];

export interface MicStartResult {
  started: boolean;
  /** The rate actually granted. Only meaningful when started is true. */
  sampleRate: number;
  /** Human-readable reason when started is false. */
  message: string;
}

/** Ask for microphone access. Returns true if granted. */
export async function requestMicPermission(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const atManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(context, [MIC_PERMISSION]);
    const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
    hilog.info(DOMAIN, TAG, 'Microphone permission granted: %{public}s', `${granted}`);
    return granted;
  } catch (err) {
    const e = err as BusinessError;
    hilog.error(DOMAIN, TAG, 'Permission request failed: %{public}s', e.message);
    return false;
  }
}

export class MicSource {
  private capturer: audio.AudioCapturer | undefined = undefined;
  private sampleRate: number = 0;
  private capturing: boolean = false;
  private onData: ((buffer: ArrayBuffer) => void) | undefined = undefined;

  getSampleRate(): number {
    return this.sampleRate;
  }

  isCapturing(): boolean {
    return this.capturing;
  }

  /**
   * Create the capturer and start delivering buffers to `onData`.
   *
   * Tries each candidate rate in turn. A wearable that rejects 44.1 kHz still gets a
   * working analyser at 16 kHz — with a 5.5 kHz Nyquist limit and 3.9 Hz bins at
   * N = 4096, which the Readout page shows so the trade-off isn't invisible.
   */
  async start(onData: (buffer: ArrayBuffer) => void): Promise<MicStartResult> {
    if (this.capturing) {
      const already: MicStartResult = {
        started: true, sampleRate: this.sampleRate, message: 'already capturing'
      };
      return already;
    }

    this.onData = onData;
    let lastError: string = 'no supported sample rate';

    for (let i: number = 0; i < CANDIDATE_RATES.length; i++) {
      const rate: number = CANDIDATE_RATES[i];
      try {
        const streamInfo: audio.AudioStreamInfo = {
          samplingRate: rate,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        };
        const capturerInfo: audio.AudioCapturerInfo = {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        };
        const options: audio.AudioCapturerOptions = {
          streamInfo: streamInfo,
          capturerInfo: capturerInfo
        };

        const capturer = await audio.createAudioCapturer(options);
        capturer.on('readData', (buffer: ArrayBuffer) => {
          if (this.capturing && this.onData !== undefined) {
            this.onData(buffer);
          }
        });
        await capturer.start();

        this.capturer = capturer;
        this.sampleRate = rate;
        this.capturing = true;

        hilog.info(DOMAIN, TAG, 'Capturing at %{public}d Hz', rate);
        const ok: MicStartResult = { started: true, sampleRate: rate, message: '' };
        return ok;
      } catch (err) {
        const e = err as BusinessError;
        lastError = `${rate} Hz rejected: ${e.message}`;
        hilog.warn(DOMAIN, TAG, '%{public}s', lastError);
      }
    }

    const failed: MicStartResult = { started: false, sampleRate: 0, message: lastError };
    return failed;
  }

  /** Stop and release. Safe to call when not capturing. */
  async stop(): Promise<void> {
    this.capturing = false;
    this.onData = undefined;

    const capturer = this.capturer;
    this.capturer = undefined;
    if (capturer === undefined) {
      return;
    }

    try {
      await capturer.stop();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'stop failed: %{public}s', (err as BusinessError).message);
    }
    try {
      await capturer.release();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'release failed: %{public}s', (err as BusinessError).message);
    }
  }
}
