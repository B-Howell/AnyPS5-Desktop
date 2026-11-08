import unittest

from rollback import Impairment, simulate


class CounterCore:
    def __init__(self):
        self.frame = self.image = 0
        self.state_size = 8

    def advance(self, count, p1, p2):
        for _ in range(count):
            self.image = (self.image * 5 + p1 * 11 + p2 * 17) % 65521
            self.frame += 1

    def checkpoint(self):
        return self.image

    def restore(self, frame, state, image):
        self.frame, self.image = frame, state

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

    def test_rollback_reduces_stalls_against_lockstep(self):
        network = Impairment(35, 0, 0, None)
        lockstep = simulate(CounterCore(), self.inputs, self.baseline, 0, network, 1, 0, 7)
        rollback = simulate(CounterCore(), self.inputs, self.baseline, 0, network, 1, 8, 7)
        self.assertTrue(lockstep["matched"] and rollback["matched"])
        self.assertEqual(lockstep["rollbacks"], 0)
        self.assertLess(rollback["stall_ticks"], lockstep["stall_ticks"])
        self.assertLess(rollback["input_ticks"]["p95"], lockstep["input_ticks"]["p95"])

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
