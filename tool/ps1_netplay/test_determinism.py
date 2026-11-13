import struct
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from determinism import compare, ctr_finish, cue_identity, normalize_trace
from late_join import CARD_MARKER, export_portable


class DeterminismTests(unittest.TestCase):
    def test_blank_card_fixture_restores_source_when_export_raises(self):
        card = bytearray(b"x" * (2 * len(CARD_MARKER)))
        clean = bytes(len(card))

        def fail_export(*_args):
            self.assertEqual(card, clean)
            raise OSError("Synthetic exporter error")

        core = SimpleNamespace(
            bind=lambda *_args: fail_export, state_size=64, read_ram=lambda: b"",
        )
        with self.assertRaisesRegex(OSError, "Synthetic exporter error"):
            export_portable(core, bytes(32), card, clean)
        self.assertEqual(card, b"x" * len(CARD_MARKER) + CARD_MARKER)

    def test_cue_identity_ignores_paths_but_covers_layout_and_bytes(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "a"
            second = root / "b"
            for folder, name in ((first, "first"), (second, "second")):
                folder.mkdir()
                (folder / f"{name}.bin").write_bytes(b"disc")
                (folder / "disc.cue").write_text(
                    f'FILE "{name}.bin" BINARY\n TRACK 01 MODE2/2352\n INDEX 01 00:00:00\n'
                )
            baseline = cue_identity(first / "disc.cue")
            self.assertEqual(baseline, cue_identity(second / "disc.cue"))
            (second / "second.bin").write_bytes(b"other")
            self.assertNotEqual(baseline, cue_identity(second / "disc.cue"))

    def test_normalize_trace_rejects_invalid_counts_and_masks(self):
        self.assertEqual(normalize_trace([[2, 64, 128]]), [(2, 64, 128)])
        for bad in ([[0, 0, 0]], [[3, -1, 0]], [[3, 0]], [[1, 65536, 0]], [[True, 0, 0]]):
            with self.assertRaises(ValueError):
                normalize_trace(bad)

    def test_ctr_finish_requires_game_end_and_three_laps_for_winner(self):
        ram = bytearray(2 * 1024 * 1024)
        tracker = 0x096B20
        struct.pack_into("<I", ram, tracker, 0x200000)
        ram[tracker + 0x1CA8] = 2
        ram[tracker + 0x1D33] = 3
        drivers = (0x0A0000, 0x0B0000)
        struct.pack_into("<II", ram, tracker + 0x24EC, *(0x80000000 + d for d in drivers))
        for rank, driver in enumerate(drivers):
            ram[driver + 0x44] = 3 - rank
            struct.pack_into("<I", ram, driver + 0x2C8, 0x02000000)
            struct.pack_into("<h", ram, driver + 0x482, rank)

        def read(offset, length):
            return ram[offset:offset + length]

        self.assertEqual(ctr_finish(read)[0], {"rank": 1, "laps": 3, "finished": True})
        ram[drivers[0] + 0x44] = 2
        with self.assertRaisesRegex(ValueError, "winner"):
            ctr_finish(read)
        struct.pack_into("<I", ram, tracker, 0)
        with self.assertRaisesRegex(ValueError, "did not reach"):
            ctr_finish(read)

    def test_reports_first_difference_and_refuses_empty_runs(self):
        one = [{"frame": 60, "ram": "a"}, {"frame": 120, "ram": "b"}]
        other = [{"frame": 60, "ram": "a"}, {"frame": 120, "ram": "c"}]
        self.assertEqual(compare(one, other)["frame"], 120)
        self.assertIsNone(compare(one, one))
        with self.assertRaises(ValueError):
            compare([], [])


if __name__ == "__main__":
    unittest.main()
