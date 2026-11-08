"""Compare independent headless PS1 runs and each worker's checkpoint replay."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import itertools
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import time

from headless_core import Core

CTR_USA_CUE = "7061d0d774c4d73bd3bc90afaa1b6d35a9fcdd797c5d92d973af55423e2ce59f"
CUE_FILE = re.compile(r'^FILE\s+(?:"([^"]+)"|(\S+))\s+(\S+)\s*$', re.IGNORECASE)


def cue_identity(cue):
    if cue.suffix.lower() != ".cue":
        raise ValueError("Expected a CUE sheet")
    lines = []
    files = 0
    for line in cue.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.upper().startswith("REM "):
            continue
        if line.split()[0].upper() == "FILE":
            match = CUE_FILE.fullmatch(line)
            if match is None:
                raise ValueError(f"Unsupported CUE FILE line: {line}")
            name, unquoted, file_type = match.groups()
            path = cue.parent / (name or unquoted)
            lines.append(f"FILE {file_type.upper()} {file_digest(path)}")
            files += 1
        else:
            lines.append(" ".join(line.upper().split()))
    if not files or not any(line.startswith("TRACK ") for line in lines):
        raise ValueError("CUE has no tracks")
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def file_digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def normalize_trace(trace):
    if not isinstance(trace, list) or not trace:
        raise ValueError("Trace must contain frame spans")
    spans = []
    for span in trace:
        if (
            not isinstance(span, list) or len(span) != 3
            or any(type(item) is not int for item in span)
            or span[0] <= 0 or any(not 0 <= mask <= 65535 for mask in span[1:])
        ):
            raise ValueError("A span must be [positive frame count, P1 mask, P2 mask]")
        spans.append(tuple(span))
    if sum(span[0] for span in spans) > 200_000:
        raise ValueError("Trace exceeds 200000 frames")
    return spans


def compare(baseline, candidate):
    if not baseline or not candidate:
        raise ValueError("Missing signatures")
    for left, right in itertools.zip_longest(baseline, candidate):
        if left != right:
            return {"frame": (left or right)["frame"], "baseline": left, "candidate": right}
    return None


def replay(core, frames):
    for (p1, p2), span in itertools.groupby(frames):
        core.advance(sum(1 for _ in span), p1, p2)


def ctr_finish(read_ram):
    tracker = 0x096B20
    mode = struct.unpack("<I", read_ram(tracker, 4))[0]
    players = read_ram(tracker + 0x1CA8, 1)[0]
    laps = read_ram(tracker + 0x1D33, 1)[0]
    if not mode & 0x200000 or players != 2 or laps != 3:
        raise ValueError("CTR did not reach the end of a three-lap two-player race")
    drivers = struct.unpack("<II", read_ram(tracker + 0x24EC, 8))
    racers = []
    for pointer in drivers:
        driver = pointer & 0x1FFFFF
        if not 0x80000000 <= pointer < 0x80200000 or not 0 < driver < 0x200000 - 0x484:
            raise ValueError("CTR race has an invalid driver pointer")
        lap = read_ram(driver + 0x44, 1)[0]
        flags = struct.unpack("<I", read_ram(driver + 0x2C8, 4))[0]
        rank = struct.unpack("<h", read_ram(driver + 0x482, 2))[0]
        racers.append({"rank": rank + 1, "laps": lap, "finished": bool(flags & 0x02000000)})
    if sorted(racer["rank"] for racer in racers) != [1, 2] or not all(r["finished"] for r in racers):
        raise ValueError("CTR did not produce two finished placements")
    if not any(r["rank"] == 1 and r["laps"] == laps for r in racers):
        raise ValueError("The CTR winner did not complete three laps")
    return racers


def run_worker(args, frames, windows):
    core = Core(args.core, args.disc, args.bios, args.output, args.cpu)
    try:
        boundaries = set(range(args.interval, len(frames), args.interval)) | {len(frames)}
        boundaries.update(end for _, end in windows)
        starts = {start for start, _ in windows}
        states = {}
        signatures = []
        costs = []
        for end in sorted(boundaries | starts):
            replay(core, frames[core.frame:end])
            if end in boundaries:
                signatures.append(core.signature())
            if end in starts:
                before = time.perf_counter()
                states[end] = (core.checkpoint(), core.image)
                costs.append(round((time.perf_counter() - before) * 1000, 3))
        finish = ctr_finish(core.read_ram) if args.ctr_finish else None
        if args.ctr_finish and (not all(core.pressed_reads) or core.image is None):
            raise ValueError("CTR finish requires video and inputs consumed on both ports")
        reference = {sample["frame"]: sample for sample in signatures}
        pad_reads = core.pressed_reads.copy()
        replays = []
        for start, end in windows:
            before = time.perf_counter()
            core.restore(start, *states[start])
            restore_ms = round((time.perf_counter() - before) * 1000, 3)
            before = time.perf_counter()
            replay(core, frames[start:end])
            replay_ms = round((time.perf_counter() - before) * 1000, 3)
            result = core.signature()
            replays.append({
                "start": start, "end": end, "restore_ms": restore_ms, "replay_ms": replay_ms,
                "difference": compare([reference[end]], [result]),
            })
        result = {
            "signatures": signatures, "pressed_reads": pad_reads, "state_bytes": core.state_size,
            "checkpoint_ms": costs, "replays": replays, "finish": finish,
            "options": {key.decode(): value.decode() for key, value in core.settings.items()},
        }
        (args.output / "run.json").write_text(json.dumps(result, indent=2))
    finally:
        core.close()


def compare_workers(args, windows):
    identity = {
        "cue": cue_identity(args.disc), "bios": file_digest(args.bios),
        "core": file_digest(args.core), "trace": file_digest(args.trace),
    }
    if args.ctr_finish and identity["cue"] != CTR_USA_CUE:
        raise ValueError("CTR finish probe requires the pinned USA disc")
    args.output.mkdir()

    def launch(index):
        worker = args.output / f"worker-{index + 1}"
        command = [
            sys.executable, "-B", str(Path(__file__).resolve()), "--worker",
            "--core", str(args.core), "--disc", str(args.disc), "--bios", str(args.bios),
            "--trace", str(args.trace), "--output", str(worker), "--interval", str(args.interval),
            "--cpu", args.cpu,
        ]
        if args.ctr_finish:
            command.append("--ctr-finish")
        for start, end in windows:
            command.extend(["--replay", f"{start}:{end}"])
        with (args.output / f"worker-{index + 1}.log").open("w") as log:
            subprocess.run(
                command, cwd=args.output, stdout=log, stderr=subprocess.STDOUT, check=True,
                timeout=300, creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS,
            )
        print(f"Worker {index + 1} completed", flush=True)
        return json.loads((worker / "run.json").read_text())

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(launch, range(args.runs)))
    baseline = results[0]
    differences = [compare(baseline["signatures"], result["signatures"]) for result in results[1:]]
    options_match = all(result["options"] == baseline["options"] for result in results)
    success = options_match and not any(differences) and all(
        replayed["difference"] is None for result in results for replayed in result["replays"]
    )
    summary = {
        "matched": success, "identity": identity, "runs": args.runs, "interval": args.interval,
        "samples_per_run": len(baseline["signatures"]), "first_differences": differences,
        "frames": baseline["signatures"][-1]["frame"], "options_match": options_match,
        "replay_results": [result["replays"] for result in results],
        "pressed_reads": [result["pressed_reads"] for result in results],
        "state_bytes": baseline["state_bytes"],
        "checkpoint_ms": [result["checkpoint_ms"] for result in results],
        "finish": [result["finish"] for result in results],
    }
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if success else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("core", "disc", "bios", "trace", "output"):
        parser.add_argument(f"--{name}", required=True, type=lambda path: Path(path).resolve())
    parser.add_argument("--cpu", choices=("Recompiler", "Interpreter"), default="Recompiler")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--interval", type=int, default=60)
    parser.add_argument("--replay", action="append", default=[], metavar="START:END")
    parser.add_argument("--ctr-finish", action="store_true", help="Require a completed race on the pinned USA disc")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "win32" or not 2 <= args.runs <= 8 or args.interval < 1:
        parser.error("Windows required, with 2-8 runs and a positive sample interval")
    try:
        spans = normalize_trace(json.loads(args.trace.read_text(encoding="utf-8-sig")))
        windows = [tuple(map(int, window.split(":"))) for window in args.replay]
        count = sum(span[0] for span in spans)
        if len(windows) > 8 or any(not 0 < start < end <= count for start, end in windows):
            raise ValueError("Expected at most eight START:END intervals within the trace")
    except (ValueError, OSError) as error:
        parser.error(str(error))
    if args.worker:
        if args.ctr_finish and cue_identity(args.disc) != CTR_USA_CUE:
            parser.error("CTR finish probe requires the pinned USA disc")
        frames = [(p1, p2) for count, p1, p2 in spans for _ in range(count)]
        run_worker(args, frames, windows)
        return 0
    return compare_workers(args, windows)


if __name__ == "__main__":
    sys.exit(main())
