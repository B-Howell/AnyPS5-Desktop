"""Headless PS1 rollback trial with deterministic virtual packet delivery."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
import heapq
import json
import math
from pathlib import Path
import random
import subprocess
import sys
from time import perf_counter

from determinism import CTR_USA_CUE, ctr_finish, cue_identity, file_digest, normalize_trace
from headless_core import Core

TICK_MS = 1000 / 60
HISTORY = 16
MAX_TAIL_TICKS = 120


@dataclass(frozen=True)
class Impairment:
    one_way_ms: float
    jitter_ms: float
    loss: float
    burst: tuple[int, int] | None


PROFILES = {
    "clean": Impairment(0, 0, 0, None),
    "40ms": Impairment(20, 0, 0, None),
    "80ms-jitter": Impairment(40, 15, 0, None),
    "80ms-loss": Impairment(40, 15, 0.02, (5600, 5607)),
    "120ms-loss": Impairment(60, 25, 0.05, (5600, 5610)),
}


class PacketLink:
    def __init__(self, profile, seed):
        self.profile = profile
        self.random = random.Random(seed)
        self.queue = []
        self.sent = self.dropped = self.reordered = 0
        self.highest_sequence = -1

    def send(self, tick, start, inputs):
        self.sent += 1
        profile = self.profile
        if (
            self.random.random() < profile.loss
            or (profile.burst and profile.burst[0] <= tick < profile.burst[1])
        ):
            self.dropped += 1
            return
        delay = profile.one_way_ms + self.random.uniform(-profile.jitter_ms, profile.jitter_ms)
        arrival = tick + max(0, math.ceil(delay / TICK_MS))
        heapq.heappush(self.queue, (arrival, tick, start, inputs))

    def receive(self, tick):
        while self.queue and self.queue[0][0] <= tick:
            _, sequence, start, inputs = heapq.heappop(self.queue)
            if sequence < self.highest_sequence:
                self.reordered += 1
            self.highest_sequence = max(sequence, self.highest_sequence)
            yield start, inputs


@dataclass
class PlayedFrame:
    remote: int
    signature: dict
    checkpoint: tuple | None


def distribution(samples):
    if not samples:
        return None
    values = sorted(samples)
    return {
        "p50": round(values[math.ceil(len(values) * .5) - 1], 3),
        "p95": round(values[math.ceil(len(values) * .95) - 1], 3),
        "max": round(values[-1], 3),
    }


def simulate(core, inputs, baseline, seat, network, delay, window, seed):
    """Run one peer. Its remote input becomes visible only on packet delivery."""
    local, remote = zip(*((frame[seat], frame[1 - seat]) for frame in inputs))
    link = PacketLink(network, seed)
    known = {}
    pending = {}
    confirmed = 0
    difference = None
    timings = []
    rollback_times = []
    input_ticks = []
    rollbacks = replayed = max_depth = max_checkpoints = stall_ticks = 0
    stall_streak = max_streak = 0
    finish_tick = None
    count = len(inputs)

    def advance():
        frame = core.frame + 1
        value = known.get(frame)
        checkpoint = None
        started = perf_counter()
        if value is None:
            earlier = frame - 1
            while earlier and earlier not in known:
                earlier -= 1
            value = known.get(earlier, 0)
            checkpoint = core.checkpoint(), core.image
        buttons = (local[frame - 1], value)
        core.advance(1, *(buttons if seat == 0 else buttons[::-1]))
        elapsed = (perf_counter() - started) * 1000
        pending[frame] = PlayedFrame(value, core.signature(), checkpoint)
        return elapsed

    def confirm():
        nonlocal confirmed, difference
        while confirmed < core.frame and confirmed + 1 in known:
            frame = confirmed + 1
            signature = pending.pop(frame).signature
            if signature != baseline[frame - 1]:
                difference = {"frame": frame, "expected": baseline[frame - 1], "actual": signature}
                break
            confirmed = frame

    for tick in range(count + delay + MAX_TAIL_TICKS):
        newest = min(tick + 1, count)
        start = max(1, newest - HISTORY + 1)
        link.send(tick, start, remote[start - 1:newest])
        correction = None
        for first, packet in link.receive(tick):
            for frame, value in enumerate(packet, first):
                if frame in known:
                    continue
                known[frame] = value
                if frame in pending and pending[frame].remote != value:
                    correction = frame if correction is None else min(correction, frame)

        work_ms = 0
        if correction is not None:
            prior_tip = core.frame
            depth = prior_tip - correction + 1
            max_depth = max(max_depth, depth)
            rollbacks += 1
            replayed += depth
            started = perf_counter()
            core.restore(correction - 1, *pending[correction].checkpoint)
            work_ms = (perf_counter() - started) * 1000
            while core.frame < prior_tip:
                work_ms += advance()
            rollback_times.append(work_ms)

        confirm()
        target = min(count, tick + 1 - delay)
        previous_tip = core.frame
        # At most two new frames per tick, including recovery after a stall.
        while not difference and core.frame < min(target, previous_tip + 2):
            next_frame = core.frame + 1
            if next_frame - confirmed > max(window, 1) or (window == 0 and next_frame not in known):
                break
            work_ms += advance()
            input_ticks.append(tick - (next_frame - 1))
            max_checkpoints = max(max_checkpoints, sum(record.checkpoint is not None for record in pending.values()))
            confirm()
        if work_ms:
            timings.append(work_ms)
        if previous_tip < target and core.frame == previous_tip:
            stall_ticks += 1
            stall_streak += 1
            max_streak = max(max_streak, stall_streak)
        else:
            stall_streak = 0
        if core.frame == count and finish_tick is None:
            finish_tick = tick
        if difference or confirmed == count:
            break

    return {
        "matched": difference is None and confirmed == count,
        "reason": "desync" if difference else ("finished" if confirmed == count else "timeout"),
        "first_difference": difference,
        "seat": seat + 1, "confirmed": confirmed, "total_frames": count,
        "finish_tick": finish_tick, "confirmation_tick": tick,
        "stall_ticks": stall_ticks, "max_stall_streak": max_streak,
        "input_ticks": distribution(input_ticks),
        "work_ms": distribution(timings), "rollback_work_ms": distribution(rollback_times),
        "over_budget_work_ticks": sum(value > TICK_MS for value in timings),
        "over_budget_rollback_ticks": sum(value > TICK_MS for value in rollback_times),
        "rollbacks": rollbacks, "replayed_frames": replayed, "max_rollback_depth": max_depth,
        "max_checkpoints": max_checkpoints, "checkpoint_payload_bytes": max_checkpoints * core.state_size,
        "network": {"sent": link.sent, "dropped": link.dropped, "reordered": link.reordered},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("core", "disc", "bios", "trace", "baseline", "output"):
        parser.add_argument(f"--{name}", type=lambda path: Path(path).resolve(), required=True)
    parser.add_argument("--cpu", choices=("Recompiler", "Interpreter"), default="Recompiler")
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--delay", type=int, default=2)
    parser.add_argument("--window", type=int, default=8)
    parser.add_argument("--seed", type=int, default=2401)
    parser.add_argument("--seat", type=int, choices=(0, 1), help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "win32" or not 0 <= args.delay <= 8 or not 0 <= args.window <= 8:
        parser.error("Windows required, with delay and window in 0-8 frames")
    fixture = json.loads(args.baseline.read_text())
    signatures = fixture["signatures"]
    spans = normalize_trace(json.loads(args.trace.read_text(encoding="utf-8-sig")))
    inputs = [(p1, p2) for count, p1, p2 in spans for _ in range(count)]
    if len(signatures) != len(inputs) or any(row["frame"] != frame for frame, row in enumerate(signatures, 1)):
        parser.error("Expected one baseline signature per trace frame, in order")

    profile = PROFILES[args.profile]
    if args.seat is not None:
        # A peer only reloads its own in-memory checkpoints. SwanStation uses
        # the file-style restore path for libretro's ROLLBACK_NETPLAY context.
        core = Core(args.core, args.disc, args.bios, args.output, args.cpu,
                    memory_checkpoints=True)
        try:
            if {key.decode(): value.decode() for key, value in core.settings.items()} != fixture["options"]:
                raise ValueError("Core options do not match the baseline")
            result = simulate(core, inputs, signatures, args.seat, profile, args.delay, args.window, args.seed + args.seat)
            if result["matched"]:
                result["finish"] = ctr_finish(core.read_ram)
                if result["finish"] != fixture["finish"]:
                    raise ValueError("CTR placements did not match the baseline")
            (args.output / "trial.json").write_text(json.dumps(result, indent=2))
        finally:
            core.close()
        return 0

    identity = {
        "core": file_digest(args.core), "cue": cue_identity(args.disc),
        "bios": file_digest(args.bios), "trace": file_digest(args.trace),
    }
    summary = json.loads((args.baseline.parent.parent / "summary.json").read_text())
    if not summary["matched"] or summary["identity"] != identity or identity["cue"] != CTR_USA_CUE:
        parser.error("Baseline summary must match this exact pinned CTR fixture")
    args.output.mkdir()

    def launch(seat):
        worker = args.output / f"peer-{seat + 1}"
        command = [sys.executable, "-B", str(Path(__file__).resolve())]
        for name in ("core", "disc", "bios", "trace", "baseline", "profile", "delay", "window", "seed", "cpu"):
            command.extend((f"--{name}", str(getattr(args, name))))
        command.extend(("--output", str(worker), "--seat", str(seat)))
        with (args.output / f"peer-{seat + 1}.log").open("w") as log:
            subprocess.run(command, cwd=args.output, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=600,
                           creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS)
        return json.loads((worker / "trial.json").read_text())

    with ThreadPoolExecutor(max_workers=2) as pool:
        peers = list(pool.map(launch, (0, 1)))
    result = {
        "matched": all(peer["matched"] for peer in peers), "identity": identity,
        "profile": args.profile, "network": asdict(profile), "delay": args.delay,
        "window": args.window, "seed": args.seed, "cpu": args.cpu, "peers": peers,
    }
    (args.output / "summary.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return 0 if result["matched"] else 1


if __name__ == "__main__":
    sys.exit(main())
