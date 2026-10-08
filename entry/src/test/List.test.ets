import localUnitTest from './LocalUnit.test';
import fftTest from './FftTest';

export default function testsuite() {
  localUnitTest();
  fftTest();
}
