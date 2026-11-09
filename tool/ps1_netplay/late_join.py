"""Check whether a cold peer can resume a running match's local checkpoint."""
import argparse
import ctypes
import hashlib
import itertools
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import zlib

from determinism import CTR_USA_CUE, compare, ctr_finish, cue_identity, file_digest, normalize_trace, replay
from headless_core import CPU_MODES, Core

CTR_GAME_ID = "SCUS94426"
PORTABLE_PREFIX_SIZE = 8 + 32


def identity(args, disc):
    digest = cue_identity(disc)
    if digest != CTR_USA_CUE:
        raise ValueError("The race fixture requires the verified US CTR disc")
    return {
        "game_id": CTR_GAME_ID,
        "disc_sha256": digest,
        "core_sha256": file_digest(args.core),
        "bios_sha256": file_digest(args.bios),
        "trace_sha256": file_digest(args.trace),
    }


def worker(args, frames, scratch):
    guest = args.worker == "guest"
    disc = args.guest_disc if guest else args.disc
    local_identity = identity(args, disc)
    disc_hash = bytes.fromhex(local_identity["disc_sha256"])
    cpu = "CachedInterpreter" if guest else args.host_cpu
    core = Core(args.core, disc, args.bios, scratch / args.worker, cpu,
                memory_checkpoints=True, same_binary=True, block_linking=False, inline_gpu=True)
    try:
        state_path = scratch / "state"
        manifest_path = scratch / "manifest.json"
        portable = args.checkpoint == "portable"
        if guest:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if manifest["identity"] != local_identity or manifest["frame"] != args.join_frame:
                return {"restore_error": "Checkpoint identity or frame does not match"}
            size = state_path.stat().st_size
            limit = core.state_size + PORTABLE_PREFIX_SIZE if portable else core.state_size
            if not 0 < size <= limit or size != manifest["bytes"]:
                return {"restore_error": "Checkpoint size does not match"}
            payload = state_path.read_bytes()
            if len(payload) != size or hashlib.sha256(payload).hexdigest() != manifest["sha256"]:
                return {"restore_error": "Checkpoint hash does not match"}
            state = ctypes.create_string_buffer(payload, len(payload))
            if portable:
                load = core.bind("retro_anyps5_import_checkpoint_v1", ctypes.c_bool,
                                 ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p)
                before = core.signature()
                if (load(state, len(state) - 1, disc_hash) or
                        load(state, len(state), bytes(32)) or core.signature() != before):
                    return {"restore_error": "Invalid checkpoint was accepted or changed the guest"}
                started = time.perf_counter()
                if not load(state, len(state), disc_hash):
                    return {"restore_error": "Core rejected portable checkpoint"}
                core.frame = args.join_frame
            else:
                started = time.perf_counter()
                try:
                    core.restore(args.join_frame, state)
                except RuntimeError as error:
                    return {"restore_error": str(error)}
            evidence = {"restore_ms": round((time.perf_counter() - started) * 1000, 3)}
            if portable:
                evidence["rejected_truncated_checkpoint_and_wrong_disc_hash"] = True
        else:
            replay(core, frames[:args.join_frame])
            started = time.perf_counter()
            if portable:
                save = core.bind("retro_anyps5_export_checkpoint_v1", ctypes.c_size_t,
                                 ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p)
                state = ctypes.create_string_buffer(core.state_size + PORTABLE_PREFIX_SIZE)
                size = save(state, len(state), disc_hash)
                if not 0 < size <= len(state):
                    raise RuntimeError("Core could not export a portable checkpoint")
                payload = state[:size]
            else:
                payload = core.checkpoint().raw
            evidence = {
                "capture_ms": round((time.perf_counter() - started) * 1000, 3),
                "checkpoint_bytes": len(payload),
                "compressed_bytes": len(zlib.compress(payload, level=1)),
                "found_exact_host_disc_path": str(disc).encode("utf-8") in payload,
            }
            state_path.write_bytes(payload)
            manifest_path.write_text(json.dumps({
                "identity": local_identity, "frame": args.join_frame, "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            }), encoding="utf-8")
        signatures = [core.signature() | {"video": None}]
        boundaries = [args.join_frame + 1, *range(args.join_frame + 120, len(frames), 120), len(frames)]
        for boundary in boundaries:
            replay(core, frames[core.frame:boundary])
            signatures.append(core.signature())
        try:
            finish = ctr_finish(core.read_ram)
        except ValueError as error:
            return {"evidence": evidence, "signatures": signatures, "finish_error": str(error)}
        return {"evidence": evidence, "signatures": signatures, "finish": finish}
    finally:
        core.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("core", "bios", "disc", "guest-disc", "trace"):
        parser.add_argument(f"--{name}", type=lambda value: Path(value).resolve(strict=True), required=True)
    parser.add_argument("--join-frame", type=int, default=6600)
    parser.add_argument("--host-cpu", choices=CPU_MODES, default="CachedInterpreter",
                        help="Exercise handoff from a different host CPU mode")
    parser.add_argument("--checkpoint", choices=("portable", "legacy"), default="portable")
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
    host_identity = identity(args, args.disc)
    if args.disc == args.guest_disc or host_identity != identity(args, args.guest_disc):
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
        path_leak = args.checkpoint == "portable" and host["evidence"]["found_exact_host_disc_path"]
        finish_errors = {role: result["finish_error"] for role, result in zip(("host", "guest"), results)
                         if "finish_error" in result}
        report = {
            **host_identity,
            "checkpoint_format": args.checkpoint,
            "host_cpu": args.host_cpu,
            "guest_cpu": "CachedInterpreter",
            "requested_join_frame": args.join_frame,
            "trace_frames": len(frames),
            "matched_checkpoints": len(host["signatures"]) if mismatch is None and not restore_error else None,
            "first_mismatch": mismatch,
            "restore_error": restore_error,
            "host": host["evidence"],
            "guest": guest.get("evidence"),
            "finish_errors": finish_errors,
            "finish": guest.get("finish"),
        }
        print(json.dumps(report, indent=2))
        return int(path_leak or restore_error is not None or mismatch is not None or bool(finish_errors)
                   or host.get("finish") != guest.get("finish"))


if __name__ == "__main__":
    sys.exit(main())
