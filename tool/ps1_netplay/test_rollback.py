import ctypes as c
import unittest

from headless_core import Core
from rollback import Impairment, simulate


class CheckpointContextTests(unittest.TestCase):
    def test_checkpoint_can_reuse_the_core_buffer_without_copying_it(self):
        core = Core.__new__(Core)
        core.memory_checkpoints = False
        core.state_size = 8
        core.serialize = lambda buffer, size: c.memset(buffer, 42, size)
        first = core.checkpoint()
        self.assertIs(core.checkpoint(first), first)
        self.assertEqual(bytes(first), b"*" * 8)
        with self.assertRaisesRegex(ValueError, "writable checkpoint buffer"):
            core.checkpoint(b" " * 8)
        with self.assertRaisesRegex(ValueError, "writable checkpoint buffer"):
            core.checkpoint((c.c_uint32 * 2)())

    def test_same_instance_context_is_scoped_to_checkpoint_calls(self):
        core = Core.__new__(Core)
        core.memory_checkpoints = True
        core.state_size = 1
        context = c.c_int(-1)
        command = 72 | 0x10000

        def query_context(_state, _size):
            self.assertTrue(core.environment(command, None))
            self.assertFalse(core._checkpoint_context_queried)
            self.assertTrue(core.environment(command, c.addressof(context)))
            self.assertEqual(context.value, 1)
            return True

        core.serialize = core.unserialize = query_context
        self.assertFalse(core.environment(command, c.addressof(context)))
        core.restore(12, core.checkpoint(), "framebuffer")
        self.assertEqual((core.frame, core.image), (12, "framebuffer"))
        self.assertFalse(core.environment(command, c.addressof(context)))

    def test_rollback_rejects_a_core_that_ignores_context(self):
        core = Core.__new__(Core)
        core.memory_checkpoints = True
        core.unserialize = lambda _state, _size: True
        with self.assertRaisesRegex(RuntimeError, "save-state context"):
            core.restore(12, b"state")


class CounterCore:
    def __init__(self):
        self.frame = self.image = 0
        self.state_size = 8

    def advance(self, count, p1, p2):
        for _ in range(count):
            self.image = (self.image * 5 + p1 * 11 + p2 * 17) % 65521
            self.frame += 1

    def checkpoint(self, buffer=None):
        if buffer is None:
            buffer = [None]
        buffer[0] = self.image
        return buffer

    def restore(self, frame, state, image):
        self.frame, self.image = frame, state[0]

    def signature(self):
        return {"frame": self.frame, "state": self.image}


class RollbackTests(unittest.TestCase):
    def setUp(self):
        self.inputs = [(index % 2, index // 3 % 2) for index in range(90)]
        offline = CounterCore()
        self.baseline = []
        for p1, p2 in self.inputs:
            offline.advance(1, p1, p2)
            self.baseline.append(offline.signature())

    def test_late_different_inputs_trigger_replay_on_both_ports(self):
        network = Impairment(50, 24, 0.05, (18, 24))
        for seat in (0, 1):
            result = simulate(CounterCore(), self.inputs, self.baseline, seat, network, 2, 8, 7)
            self.assertTrue(result["matched"], result)
            self.assertGreater(result["rollbacks"], 0)
            self.assertGreater(result["network"]["dropped"], 0)
            self.assertGreater(result["network"]["reordered"], 0)
            self.assertLessEqual(result["max_checkpoints"], 8)
            self.assertLessEqual(result["checkpoint_pool_bytes"], 8 * 8)

    def test_rollback_reduces_stalls_against_lockstep(self):
        network = Impairment(35, 0, 0, None)
        lockstep = simulate(CounterCore(), self.inputs, self.baseline, 0, network, 1, 0, 7)
        rollback = simulate(CounterCore(), self.inputs, self.baseline, 0, network, 1, 8, 7)
        self.assertTrue(lockstep["matched"] and rollback["matched"])
        self.assertEqual(lockstep["rollbacks"], 0)
        self.assertLess(rollback["stall_ticks"], lockstep["stall_ticks"])
        self.assertLess(rollback["input_ticks"]["p95"], lockstep["input_ticks"]["p95"])

    def test_replay_slices_keep_receiving_inputs_and_confirm_every_frame(self):
        network = Impairment(50, 24, 0.05, (18, 24))
        for seat in (0, 1):
            result = simulate(CounterCore(), self.inputs, self.baseline, seat, network, 2, 8, 7,
                              replay_steps=1)
            self.assertTrue(result["matched"], result)
            self.assertEqual(result["confirmed"], len(self.inputs))
            self.assertEqual(result["max_replay_steps"], 1)
            self.assertGreater(result["replay_slices"], result["rollbacks"])

    def test_loss_beyond_history_times_out_and_does_not_confirm_prediction(self):
        result = simulate(CounterCore(), self.inputs, self.baseline, 0, Impairment(0, 0, 1, None), 0, 4, 7)
        self.assertFalse(result["matched"])
        self.assertEqual(result["confirmed"], 0)
        self.assertEqual(result["reason"], "timeout")
        self.assertEqual(result["max_checkpoints"], 4)

    def test_future_packets_cannot_advance_past_unrecoverable_gap(self):
        core = CounterCore()
        result = simulate(core, self.inputs, self.baseline, 0, Impairment(0, 0, 0, (10, 26)), 0, 4, 7)
        self.assertEqual(result["reason"], "timeout")
        self.assertEqual(result["confirmed"], 10)
        self.assertEqual(core.frame, 14)

    def test_divergent_reference_is_rejected(self):
        wrong = self.baseline.copy()
        wrong[5] = {"frame": 6, "state": -1}
        result = simulate(CounterCore(), self.inputs, wrong, 0, Impairment(0, 0, 0, None), 0, 4, 7)
        self.assertFalse(result["matched"])
        self.assertEqual(result["first_difference"]["frame"], 6)
        self.assertEqual(result["confirmed"], 5)


if __name__ == "__main__":
    unittest.main()
