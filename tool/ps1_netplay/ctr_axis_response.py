"""Verify that CTR responds to DualShock steering on track, using three pinned replays."""

import argparse
import ctypes as c
import json
from pathlib import Path
from subprocess import CREATE_NO_WINDOW, IDLE_PRIORITY_CLASS, run
import sys

from determinism import CTR_USA_CUE, ctr_finish, cue_identity, file_digest, normalize_trace
from headless_core import Core


CORE = "5ef8eba64119146e405a90c5e9243a249c9d57c405fd75415fb4234d5b6080eb"
BIOS = "71af94d1e47a68c11e8fdb9f8368040601514a42a5a399cda48c7d3bff1e99d3"
TRACE = Path(__file__).resolve().parent / "fixtures" / "ctr_usa_coco_park_versus.json"
BRANCH_FRAME = 6600
RESPONSE_FRAME = 6660
CASES = ("buttons", "sticks", "neutral")


class DualShockCore(Core):
    def __init__(self, core, disc, bios, root):
        self.left_x = (0, 0)
        self.nonzero_reads = [0, 0]
        super().__init__(core, disc, bios, root, cpu="CachedInterpreter", block_linking=False, inline_gpu=True)
        controller = self.bind("retro_set_controller_port_device", None, c.c_uint, c.c_uint)
        for port in range(2):
            controller(port, 261)  # SwanStation's DualShock subclass.

    def input(self, port, device, index, button):
        if port < 2 and (device, index, button) == (5, 0, 0):
            axis = self.left_x[port]
            self.nonzero_reads[port] += bool(axis)
            return axis
        return super().input(port, device, index, button)


def replay_case(args):
    root = args.output / args.case
    core = DualShockCore(args.core, args.disc, args.bios, root)
    try:
        signatures = {}
        for count, first, second in normalize_trace(json.loads(TRACE.read_text(encoding="utf-8"))):
            for _ in range(count):
                buttons = (first, second)
                if core.frame >= BRANCH_FRAME and args.case != "buttons":
                    if args.case == "sticks":
                        core.left_x = tuple(32767 * (bool(mask & 128) - bool(mask & 64)) for mask in buttons)
                    buttons = tuple(mask & ~192 for mask in buttons)
                core.advance(1, *buttons)
                if core.frame == BRANCH_FRAME:
                    tracker = 0x096B20
                    if core.read_ram(tracker + 0x1CA8, 1) != b"\x02" or core.read_ram(tracker + 0x1D33, 1) != b"\x03":
                        raise RuntimeError("The replay did not reach the expected two-player race.")
                if core.frame in (BRANCH_FRAME, RESPONSE_FRAME):
                    signatures[str(core.frame)] = core.signature()
        try:
            finish = ctr_finish(core.read_ram)
        except ValueError as error:
            finish = {"unfinished": str(error)}
        result = {"frames": signatures, "axisReads": core.nonzero_reads, "finish": finish}
        (root / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    finally:
        core.close()


def verify(results):
    common = [result["frames"][str(BRANCH_FRAME)] for result in results.values()]
    if any(signature != common[0] for signature in common) or common[0]["video"] is None:
        raise RuntimeError("The controls did not start from the same rendered race frame.")
    response = {case: result["frames"][str(RESPONSE_FRAME)]["video"] for case, result in results.items()}
    if response["sticks"] is None or response["sticks"] != response["buttons"] or response["sticks"] == response["neutral"]:
        raise RuntimeError("Stick steering did not reproduce the button control and separate from neutral.")
    if not all(results["sticks"]["axisReads"]) or not isinstance(results["buttons"]["finish"], list):
        raise RuntimeError("The probe did not read both stick ports or the button control did not finish.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("core", "disc", "bios", "output"):
        parser.add_argument(f"--{name}", type=lambda path: Path(path).resolve(), required=True)
    parser.add_argument("--case", choices=CASES, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.case:
        return replay_case(args)
    if cue_identity(args.disc) != CTR_USA_CUE or file_digest(args.core) != CORE or file_digest(args.bios) != BIOS:
        parser.error("Use the pinned CTR USA disc, portable SwanStation core and verified BIOS.")

    args.output.mkdir()
    results = {}
    for case in CASES:
        with (args.output / f"{case}.log").open("w", encoding="utf-8") as log:
            run(
                [sys.executable, "-B", __file__, *sys.argv[1:], "--case", case],
                cwd=args.output, stdout=log, stderr=log, check=True, timeout=210,
                creationflags=CREATE_NO_WINDOW | IDLE_PRIORITY_CLASS,
            )
        results[case] = json.loads((args.output / case / "result.json").read_text(encoding="utf-8"))
    verify(results)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
