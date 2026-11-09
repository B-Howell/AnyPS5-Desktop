"""Check whether a cold peer can resume a running match's local checkpoint."""
import argparse
import ctypes
import itertools
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import zlib

from determinism import compare, ctr_finish, cue_identity, file_digest, normalize_trace, replay
from headless_core import Core


def worker(args, frames, scratch):
    guest = args.worker == "guest"
    disc = args.guest_disc if guest else args.disc
    core = Core(args.core, disc, args.bios, scratch / args.worker, "CachedInterpreter",
                memory_checkpoints=True, same_binary=True, block_linking=False, inline_gpu=True)
    try:
        state_path = scratch / "state"
        if guest:
            payload = state_path.read_bytes()
            if len(payload) != core.state_size:
                raise ValueError("The checkpoint size differs from the guest core's state size")
            started = time.perf_counter()
            try:
                core.restore(args.join_frame, ctypes.create_string_buffer(payload, len(payload)))
            except RuntimeError as error:
                return {"restore_error": str(error)}
            evidence = {"restore_ms": round((time.perf_counter() - started) * 1000, 3)}
        else:
            replay(core, frames[:args.join_frame])
            started = time.perf_counter()
            payload = core.checkpoint().raw
            evidence = {
                "capture_ms": round((time.perf_counter() - started) * 1000, 3),
                "checkpoint_bytes": len(payload),
                "compressed_bytes": len(zlib.compress(payload, level=1)),
                "found_exact_host_disc_path": str(disc).encode("utf-8") in payload,
            }
            state_path.write_bytes(payload)
        signatures = [core.signature() | {"video": None}]
        boundaries = [args.join_frame + 1, *range(args.join_frame + 120, len(frames), 120), len(frames)]
        for boundary in boundaries:
            replay(core, frames[core.frame:boundary])
            signatures.append(core.signature())
        return {"evidence": evidence, "signatures": signatures, "finish": ctr_finish(core.read_ram)}
    finally:
        core.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("core", "bios", "disc", "guest-disc", "trace"):
        parser.add_argument(f"--{name}", type=lambda value: Path(value).resolve(strict=True), required=True)
    parser.add_argument("--join-frame", type=int, default=6600)
    parser.add_argument("--worker", choices=("host", "guest"), help=argparse.SUPPRESS)
    parser.add_argument("--scratch", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    spans = normalize_trace(json.loads(args.trace.read_text(encoding="utf-8")))
    frames = list(itertools.chain.from_iterable(itertools.repeat((p1, p2), count) for count, p1, p2 in spans))
    if not 0 < args.join_frame < len(frames) - 1:
        parser.error("join frame must be within the race trace")
    if args.worker:
        result = worker(args, frames, args.scratch)
        (args.scratch / f"{args.worker}.json").write_text(json.dumps(result), encoding="utf-8")
        return 0
    disc_digest = cue_identity(args.disc)
    if args.disc == args.guest_disc or disc_digest != cue_identity(args.guest_disc):
        parser.error("host and guest need equivalent discs at different paths")

    with tempfile.TemporaryDirectory(prefix="anyps5-late-join-") as directory:
        scratch = Path(directory)
        results = []
        for role in ("host", "guest"):
            subprocess.run([sys.executable, "-B", __file__, *sys.argv[1:], "--worker", role, "--scratch", directory],
                           check=True, timeout=180, stdout=subprocess.DEVNULL)
            results.append(json.loads((scratch / f"{role}.json").read_text(encoding="utf-8")))
        host, guest = results
        restore_error = guest.get("restore_error")
        mismatch = None if restore_error else compare(host["signatures"], guest["signatures"])
        report = {
            "core_sha256": file_digest(args.core),
            "bios_sha256": file_digest(args.bios),
            "disc_sha256": disc_digest,
            "trace_sha256": file_digest(args.trace),
            "requested_join_frame": args.join_frame,
            "trace_frames": len(frames),
            "matched_checkpoints": len(host["signatures"]) if mismatch is None and not restore_error else None,
            "first_mismatch": mismatch,
            "restore_error": restore_error,
            "host": host["evidence"],
            "guest": guest.get("evidence"),
            "finish": guest.get("finish"),
        }
        print(json.dumps(report, indent=2))
        return int(restore_error is not None or mismatch is not None or host["finish"] != guest["finish"])


if __name__ == "__main__":
    sys.exit(main())
