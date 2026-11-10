import unittest
import subprocess
import ctypes as c
import hashlib
from unittest.mock import Mock
from checkpoint import CheckpointCore, compare, validate_fixture, wait_owned

class CheckpointReceiptTest(unittest.TestCase):
    def sample(self, **overrides):
        return dict(step=0, ram='ram', video='video', audio='audio',
                    videoFrames=60, audioFrames=48000, inputReads=[1, 1], **overrides)

    def test_exact_replay(self):
        self.assertEqual(compare([self.sample()], [self.sample()]), [])

    def test_ram_divergence_is_reported(self):
        other = self.sample(); other['ram'] = 'changed'
        self.assertEqual(compare([self.sample()], [other]), [{'step': 0, 'fields': ['ram']}])

    def test_missing_video_is_failure_even_when_both_missing(self):
        other = self.sample(); other['video'] = None
        self.assertIn('videoMissing', compare([other], [other])[0]['fields'])

    def test_no_input_or_audio_is_not_success(self):
        other = self.sample(); other.update(audioFrames=0, inputReads=[0, 1])
        fields = compare([other], [other])[0]['fields']
        self.assertIn('audioMissing', fields); self.assertIn('inputMissing', fields)

    def test_missing_samples_is_not_success(self):
        with self.assertRaises(ValueError): compare([], [])
        with self.assertRaises(ValueError): compare([self.sample()], [])

    def test_fixture_requires_all_pins_before_native_load(self):
        with self.assertRaises(ValueError): validate_fixture({'core': 'unused'})

    def test_neutral_input_before_later_press_is_valid(self):
        neutral = self.sample(); neutral['inputReads'] = [0, 0]
        self.assertEqual(compare([neutral, self.sample()], [neutral, self.sample()]), [])

    def test_cancel_kills_and_reaps_owned_worker(self):
        process = Mock(); process.wait.side_effect = [KeyboardInterrupt, 0]; process.poll.return_value = None
        with self.assertRaises(KeyboardInterrupt): wait_owned(process, 2)
        process.kill.assert_called_once(); self.assertEqual(process.wait.call_count, 2)

    def test_timeout_kills_and_reaps_owned_worker(self):
        process = Mock(); process.wait.side_effect = [subprocess.TimeoutExpired('worker', 2), 0]
        process.poll.return_value = None
        self.assertEqual(wait_owned(process, 2), 124)
        process.kill.assert_called_once(); self.assertEqual(process.wait.call_count, 2)

    def test_success_reaps_without_killing(self):
        process = Mock(); process.wait.return_value = 0; process.poll.return_value = 0
        self.assertEqual(wait_owned(process, 2), 0); process.kill.assert_not_called()

    def test_video_stream_detects_transient_difference(self):
        def stream(first):
            core = CheckpointCore.__new__(CheckpointCore)
            core.pixel = 1; core.image = None; core.video_frames = 0
            core.video_hash = hashlib.sha256()
            for value in (first, b'last'):
                data = c.create_string_buffer(value)
                core.video(c.cast(data, c.c_void_p).value, 1, 1, 4)
            self.assertEqual(core.image[-1], b'last')
            return core.video_hash.hexdigest()
        self.assertNotEqual(stream(b'aaaa'), stream(b'bbbb'))

    def test_audio_and_video_are_advertised(self):
        core = CheckpointCore.__new__(CheckpointCore); flags = c.c_uint(0)
        self.assertTrue(core.environment(47 | 0x10000, c.addressof(flags)))
        self.assertEqual(flags.value, 3)

    def test_capture_refreshes_size_after_boot(self):
        core = CheckpointCore.__new__(CheckpointCore)
        core.state_size = 4; core.bind = Mock(return_value=lambda: 8)
        core.serialize = Mock(); core._checkpoint_call = Mock(return_value=True)
        state = core.checkpoint()
        self.assertEqual(len(state), 8)
        core._checkpoint_call.assert_called_once_with(core.serialize, state, 8)

    def test_capture_rejects_unbounded_new_size(self):
        core = CheckpointCore.__new__(CheckpointCore)
        core.bind = Mock(return_value=lambda: 257 * 1024 * 1024)
        with self.assertRaises(RuntimeError): core.checkpoint()

if __name__ == '__main__': unittest.main()
