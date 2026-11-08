"""Headless PS1 rollback trial with deterministic virtual packet delivery."""
import argparse
import ctypes
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
import heapq
import json
import math
from pathlib import Path
import random
import shutil
import subprocess
import sys
from time import perf_counter, sleep

from determinism import CTR_USA_CUE, ctr_finish, cue_identity, file_digest, normalize_trace
from headless_core import CPU_MODES, Core

TICK_MS = 1000 / 60
HISTORY = 16
MAX_TAIL_TICKS = 120
MAX_PENDING_AUDITS = 24


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
    evidence: object
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


def set_current_thread_priority(priority):
    if priority is None:
        return
    if sys.platform != "win32":
        raise RuntimeError("Prediction thread priority is supported only on Windows")
    priorities = {"above-normal": 1, "highest": 2}
    if priority not in priorities:
        raise ValueError(f"Unsupported prediction thread priority: {priority}")
    kernel32 = ctypes.windll.kernel32
    kernel32.GetCurrentThread.restype = ctypes.c_void_p
    kernel32.GetCurrentThread.argtypes = []
    kernel32.SetThreadPriority.argtypes = [ctypes.c_void_p, ctypes.c_int]
    kernel32.SetThreadPriority.restype = ctypes.c_int
    if not kernel32.SetThreadPriority(
        kernel32.GetCurrentThread(), priorities[priority]
    ):
        raise ctypes.WinError()


def simulate(core, inputs, baseline, seat, network, delay, window, seed, *, replay_steps=8,
             presentation=None, audit=None, paced=False, replay_yield_ms=None):
    """Run one peer. Its remote input becomes visible only on packet delivery."""
    local, remote = zip(*((frame[seat], frame[1 - seat]) for frame in inputs))
    link = PacketLink(network, seed)
    known = {}
    pending = {}
    checkpoint_buffers = [None] * window
    confirmed = 0
    validated = 0
    audit_jobs = deque()
    difference = None
    timings = []
    tick_times = []
    slow_ticks = []
    deadline_misses = 0
    rollback_times = []
    input_ticks = []
    rollbacks = replayed = max_depth = max_checkpoints = stall_ticks = 0
    replay_tip = replay_slices = max_replay_steps = replay_yield_ticks = 0
    max_primary_steps = 0
    last_step_ms = 0.0
    headroom_prediction_starts = 0
    stall_streak = max_streak = 0
    finish_tick = None
    count = len(inputs)
    presented = prediction_lane_ticks = max_presentation_lag = 0
    presenting = False
    presentation_state = None

    def remote_value(frame):
        while frame and frame not in known:
            frame -= 1
        return known.get(frame, 0)

    def buttons_for(frame, value):
        buttons = (local[frame - 1], value)
        return buttons if seat == 0 else buttons[::-1]

    def present(spare, start, buttons):
        if start is not None:
            spare.restore(*start)
        for masks in buttons:
            spare.advance(1, *masks)
        return spare.frame

    def advance():
        nonlocal max_checkpoints, last_step_ms
        frame = core.frame + 1
        value = known.get(frame)
        checkpoint = None
        started = perf_counter()
        if value is None:
            value = remote_value(frame - 1)
            # The confirmed frontier bounds the pending frames to one window.
            # During replay the old state is read before its slot is overwritten.
            slot = (frame - 1) % window
            buffer = core.checkpoint(checkpoint_buffers[slot])
            checkpoint_buffers[slot] = buffer
            checkpoint = buffer, core.image
        core.advance(1, *buttons_for(frame, value))
        elapsed = (perf_counter() - started) * 1000
        evidence = core.signature() if audit is None else core.signature_snapshot()
        pending[frame] = PlayedFrame(value, evidence, checkpoint)
        max_checkpoints = max(max_checkpoints, sum(record.checkpoint is not None for record in pending.values()))
        last_step_ms = elapsed
        return elapsed

    def validate(frame, signature):
        nonlocal validated, difference
        if signature != baseline[frame - 1]:
            difference = {"frame": frame, "expected": baseline[frame - 1], "actual": signature}
        else:
            validated = frame

    def poll_audit(wait=False):
        while audit_jobs and not difference and (wait or audit_jobs[0][1].done()):
            frame, job = audit_jobs.popleft()
            validate(frame, job.result())
            wait = False

    def confirm():
        nonlocal confirmed
        poll_audit()
        while not difference and confirmed < core.frame and confirmed + 1 in known:
            frame = confirmed + 1
            evidence = pending.pop(frame).evidence
            if audit is None:
                validate(frame, evidence)
            else:
                audit_jobs.append((frame, audit.submit(core.hash_signature, frame, evidence)))
                poll_audit(wait=len(audit_jobs) >= MAX_PENDING_AUDITS)
            confirmed = frame

    epoch = perf_counter()
    for tick in range(count + delay + MAX_TAIL_TICKS):
        if paced:
            ready = epoch + tick * (TICK_MS / 1000)
            remaining = ready - perf_counter()
            if remaining > 0:
                sleep(remaining)
        tick_start = perf_counter()
        newest = min(tick + 1, count)
        start = max(1, newest - HISTORY + 1)
        link.send(tick, start, remote[start - 1:newest])
        correction = None
        for first, packet in link.receive(tick):
            for frame, value in enumerate(packet, first):
                if frame in known:
                    continue
                known[frame] = value
                if frame <= core.frame and frame in pending and pending[frame].remote != value:
                    correction = frame if correction is None else min(correction, frame)

        target = min(count, tick + 1 - delay)
        old_presented = presented
        pending_presentation = None
        start = None
        handoff_save_ms = prediction_wait_ms = 0
        depth = core.frame - correction + 1 if correction is not None else 0
        new_steps = min(2, max(0, target - core.frame))
        planned_steps = depth + new_steps
        # Reserve time for restores, snapshots and callbacks when a recent
        # step suggests replay plus forward work may be too expensive inline.
        low_headroom = (replay_yield_ms is not None and new_steps > 0
                        and planned_steps * last_step_ms >= TICK_MS - replay_yield_ms)
        # A new frame and its corrections share a tick. Account for both
        # before choosing the lane rather than spending the entire cap on replay.
        if (presentation is not None and not presenting and correction is not None
                and (planned_steps > replay_steps or low_headroom)):
            headroom_prediction_starts += int(planned_steps <= replay_steps)
            started = perf_counter()
            presentation_state = core.checkpoint(presentation_state)
            handoff_save_ms = (perf_counter() - started) * 1000
            start = (core.frame, presentation_state, core.image)
            presenting = True
        if presenting:
            spare, executor = presentation
            # Keep generating new speculative frames while the verified lane
            # works from the corrected input. The spare is never confirmed.
            tip = min(target, presented + 2, confirmed + window)
            buttons = [buttons_for(frame, remote_value(frame)) for frame in range(presented + 1, tip + 1)]
            pending_presentation = executor.submit(present, spare, start, buttons)
            replay_tip = max(replay_tip, tip)

        work_ms = 0
        if correction is not None:
            replay_tip = max(replay_tip, core.frame)
            max_depth = max(max_depth, depth)
            rollbacks += 1
            started = perf_counter()
            core.restore(correction - 1, *pending[correction].checkpoint)
            work_ms = (perf_counter() - started) * 1000
        primary_start = core.frame
        if core.frame < replay_tip:
            limit = min(replay_steps, replay_tip - core.frame)
            steps = 0
            while steps < limit:
                if (steps and presenting and replay_yield_ms is not None
                        and (perf_counter() - tick_start) * 1000 >= replay_yield_ms):
                    replay_yield_ticks += 1
                    break
                work_ms += advance()
                steps += 1
            replayed += steps
            replay_slices += 1
            max_replay_steps = max(max_replay_steps, steps)
            rollback_times.append(work_ms)

        confirm()
        previous_tip = core.frame
        # At most two new frames per tick, including recovery after a stall.
        forward_limit = min(target, previous_tip + 2)
        if presentation is not None:
            forward_limit = min(forward_limit, primary_start + replay_steps)
        while not presenting and not difference and replay_tip <= core.frame < forward_limit:
            next_frame = core.frame + 1
            if next_frame - confirmed > max(window, 1) or (window == 0 and next_frame not in known):
                break
            work_ms += advance()
            input_ticks.append(tick - (next_frame - 1))
            confirm()
        if pending_presentation is not None:
            started = perf_counter()
            presented = pending_presentation.result()
            prediction_wait_ms = (perf_counter() - started) * 1000
            input_ticks.extend(tick - (frame - 1) for frame in range(old_presented + 1, presented + 1))
            prediction_lane_ticks += 1
            max_presentation_lag = max(max_presentation_lag, presented - core.frame)
            presenting = core.frame < presented
        else:
            presented = max(presented, core.frame)
        max_primary_steps = max(max_primary_steps, core.frame - primary_start)
        if work_ms:
            timings.append(work_ms)
        if old_presented < target and presented == old_presented:
            stall_ticks += 1
            stall_streak += 1
            max_streak = max(max_streak, stall_streak)
        else:
            stall_streak = 0
        if presented == count and finish_tick is None:
            finish_tick = tick
        ended = perf_counter()
        tick_ms = (ended - tick_start) * 1000
        if paced and ended > ready + TICK_MS / 1000:
            deadline_misses += 1
        tick_times.append(tick_ms)
        if tick_ms > TICK_MS:
            heapq.heappush(slow_ticks, (tick_ms, tick, presented, work_ms, pending_presentation is not None,
                                       handoff_save_ms, prediction_wait_ms, core.frame - primary_start))
            if len(slow_ticks) > 8:
                heapq.heappop(slow_ticks)
        if difference or confirmed == count:
            break

    while audit_jobs and not difference:
        poll_audit(wait=True)
    return {
        "matched": difference is None and validated == count,
        "reason": "desync" if difference else ("finished" if validated == count else "timeout"),
        "first_difference": difference,
        "seat": seat + 1, "confirmed": validated, "total_frames": count,
        "finish_tick": finish_tick, "confirmation_tick": tick,
        "stall_ticks": stall_ticks, "max_stall_streak": max_streak,
        "input_ticks": distribution(input_ticks),
        "work_ms": distribution(timings), "rollback_work_ms": distribution(rollback_times),
        "tick_ms": distribution(tick_times),
        "over_budget_ticks": sum(value > TICK_MS for value in tick_times),
        "deadline_misses": deadline_misses if paced else None,
        "slow_ticks": [
            {"tick": tick, "frame": frame, "elapsed_ms": round(elapsed, 3),
             "primary_core_ms": round(work, 3), "prediction_lane": on_lane, "primary_steps": steps,
             "handoff_save_ms": round(save, 3), "prediction_wait_ms": round(wait, 3)}
            for elapsed, tick, frame, work, on_lane, save, wait, steps in sorted(slow_ticks, reverse=True)
        ],
        "over_budget_work_ticks": sum(value > TICK_MS for value in timings),
        "over_budget_rollback_ticks": sum(value > TICK_MS for value in rollback_times),
        "rollbacks": rollbacks, "replayed_frames": replayed, "max_rollback_depth": max_depth,
        "replay_slices": replay_slices, "max_replay_steps": max_replay_steps,
        "replay_yield_ticks": replay_yield_ticks,
        "headroom_prediction_starts": headroom_prediction_starts,
        "max_primary_steps": max_primary_steps,
        "prediction_lane_ticks": prediction_lane_ticks, "max_presentation_lag": max_presentation_lag,
        "max_checkpoints": max_checkpoints, "checkpoint_payload_bytes": max_checkpoints * core.state_size,
        "checkpoint_pool_bytes": sum(buffer is not None for buffer in checkpoint_buffers) * core.state_size,
        "prediction_transfer_bytes": core.state_size if presentation_state is not None else 0,
        "network": {"sent": link.sent, "dropped": link.dropped, "reordered": link.reordered},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("core", "disc", "bios", "trace", "baseline", "output"):
        parser.add_argument(f"--{name}", type=lambda path: Path(path).resolve(), required=True)
    parser.add_argument("--cpu", choices=CPU_MODES, default="Recompiler")
    parser.add_argument("--inline-gpu", action="store_true", help="Run software GPU commands on the core thread")
    parser.add_argument("--no-block-linking", action="store_true", help="Disable recompiler block linking")
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--delay", type=int, default=2)
    parser.add_argument("--window", type=int, default=8)
    parser.add_argument("--replay-steps", type=int, choices=range(1, HISTORY + 1), default=8,
                        help="Maximum replay frames per tick, shared with new frames when using the prediction lane")
    parser.add_argument("--prediction-lane", action="store_true",
                        help="Use a separate software core to present predictions during long corrections")
    parser.add_argument("--replay-yield-ms", type=float,
                        help="Defer extra replay steps once an active prediction tick reaches this elapsed time")
    parser.add_argument("--benchmark-priority", choices=("idle", "below-normal", "normal", "above-normal"),
                        default="idle", help="Windows priority class for the headless test workers only")
    parser.add_argument("--prediction-thread-priority", choices=("above-normal", "highest"),
                        help="Optional priority for the prediction worker thread only")
    parser.add_argument("--pace", action="store_true", help="Run virtual ticks on scheduled 60 Hz wall-clock deadlines")
    parser.add_argument("--require-frame-budget", action="store_true",
                        help="Fail if a peer stalls or a whole tick exceeds 16.67 ms")
    parser.add_argument("--seed", type=int, default=2401)
    parser.add_argument("--seat", type=int, choices=(0, 1), help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "win32" or not 0 <= args.delay <= 8 or not 0 <= args.window <= HISTORY:
        parser.error(f"Windows required, with delay in 0-8 and window in 0-{HISTORY} frames")
    if args.replay_yield_ms is not None and not (args.prediction_lane and 0 < args.replay_yield_ms < TICK_MS):
        parser.error("Replay yield requires the prediction lane and a threshold between zero and one tick")
    if args.prediction_thread_priority is not None and not args.prediction_lane:
        parser.error("Prediction thread priority requires --prediction-lane")
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
                    memory_checkpoints=True, block_linking=not args.no_block_linking, inline_gpu=args.inline_gpu)
        try:
            if {key.decode(): value.decode() for key, value in core.settings.items()} != fixture["options"]:
                raise ValueError("Core options do not match the baseline")
            trial_args = (core, inputs, signatures, args.seat, profile, args.delay, args.window, args.seed + args.seat)
            if args.prediction_lane:
                spare_dll = args.output / args.core.name
                shutil.copyfile(args.core, spare_dll)
                spare = Core(spare_dll, args.disc, args.bios, args.output / "prediction", args.cpu,
                             memory_checkpoints=True, same_binary=True, block_linking=not args.no_block_linking,
                             inline_gpu=args.inline_gpu)
                try:
                    if spare.settings != core.settings:
                        raise ValueError("Prediction core options do not match the primary core")
                    with ThreadPoolExecutor(
                        max_workers=1,
                        initializer=set_current_thread_priority,
                        initargs=(args.prediction_thread_priority,),
                    ) as executor, ThreadPoolExecutor(max_workers=1) as audit:
                        result = simulate(*trial_args, replay_steps=args.replay_steps, presentation=(spare, executor),
                                          audit=audit, paced=args.pace, replay_yield_ms=args.replay_yield_ms)
                finally:
                    spare.close()
            else:
                result = simulate(*trial_args, replay_steps=args.replay_steps, paced=args.pace)
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
        for name in ("core", "disc", "bios", "trace", "baseline", "profile", "delay", "window", "replay_steps", "seed", "cpu"):
            command.extend((f"--{name.replace('_', '-')}", str(getattr(args, name))))
        command.extend(("--output", str(worker), "--seat", str(seat)))
        if args.no_block_linking:
            command.append("--no-block-linking")
        if args.inline_gpu:
            command.append("--inline-gpu")
        if args.prediction_lane:
            command.append("--prediction-lane")
        if args.prediction_thread_priority is not None:
            command.extend(("--prediction-thread-priority", args.prediction_thread_priority))
        if args.replay_yield_ms is not None:
            command.extend(("--replay-yield-ms", str(args.replay_yield_ms)))
        if args.pace:
            command.append("--pace")
        priority = {
            "idle": subprocess.IDLE_PRIORITY_CLASS,
            "below-normal": subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            "normal": subprocess.NORMAL_PRIORITY_CLASS,
            "above-normal": subprocess.ABOVE_NORMAL_PRIORITY_CLASS,
        }[args.benchmark_priority]
        with (args.output / f"peer-{seat + 1}.log").open("w") as log:
            subprocess.run(command, cwd=args.output, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=600,
                           creationflags=subprocess.CREATE_NO_WINDOW | priority)
        return json.loads((worker / "trial.json").read_text())

    with ThreadPoolExecutor(max_workers=2) as pool:
        peers = list(pool.map(launch, (0, 1)))
    result = {
        "matched": all(peer["matched"] for peer in peers), "identity": identity,
        "frame_budget_met": all(peer["matched"] and not (peer["over_budget_ticks"] or peer["stall_ticks"]
                                                       or peer["deadline_misses"])
                                for peer in peers),
        "profile": args.profile, "network": asdict(profile), "delay": args.delay,
        "window": args.window, "replay_steps": args.replay_steps, "seed": args.seed, "cpu": args.cpu,
        "block_linking_disabled": args.no_block_linking, "prediction_lane": args.prediction_lane, "peers": peers,
        "benchmark_priority": args.benchmark_priority, "paced": args.pace,
        "inline_gpu": args.inline_gpu,
        "replay_yield_ms": args.replay_yield_ms,
        "prediction_thread_priority": args.prediction_thread_priority,
    }
    (args.output / "summary.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return 0 if result["matched"] and (not args.require_frame_budget or result["frame_budget_met"]) else 1


if __name__ == "__main__":
    sys.exit(main())
