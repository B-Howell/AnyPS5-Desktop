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
SAVE_RAM = 0
CARD_BYTES = 128 * 1024
CARD_MARKER = b"ANYPS5 synthetic private card marker for checkpoint probe"
DESTINATION_MARKER = b"ANYPS5 synthetic pre-import destination card"


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


def scratch_card(core):
    address = core.bind("retro_get_memory_data", ctypes.c_void_p, ctypes.c_uint)(SAVE_RAM)
    size = core.bind("retro_get_memory_size", ctypes.c_size_t, ctypes.c_uint)(SAVE_RAM)
    if not address or size != CARD_BYTES:
        raise RuntimeError("Expected an isolated Libretro memory card")
    return (ctypes.c_ubyte * size).from_address(address)


def export_portable(core, disc_hash, card, blank_card):
    save = core.bind("retro_anyps5_export_checkpoint_v1", ctypes.c_size_t,
                     ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p)
    state = ctypes.create_string_buffer(core.state_size + PORTABLE_PREFIX_SIZE)
    if card is not None:
        # This core is stopped between calls to retro_run and owns only a
        # disposable fixture card. Production needs native card isolation.
        card[-len(CARD_MARKER):] = CARD_MARKER
        private_card = bytes(card)
        if CARD_MARKER in core.read_ram():
            raise RuntimeError("The synthetic marker must only be on the fixture card")
        card[:] = blank_card
    try:
        size = save(state, len(state), disc_hash)
    finally:
        if card is not None:
            card[:] = private_card
    if not 0 < size <= len(state):
        raise RuntimeError("Core could not export a portable checkpoint")
    payload = state[:size]
    if card is not None and (CARD_MARKER in payload or bytes(card) != private_card):
        raise RuntimeError("The export exposed or modified the synthetic private card")
    return payload


def worker(args, frames, scratch):
    guest = args.worker == "guest"
    restoring = args.worker != "host"
    disc = args.guest_disc if guest else args.disc
    local_identity = identity(args, disc)
    disc_hash = bytes.fromhex(local_identity["disc_sha256"])
    cpu = args.match_cpu if restoring else args.host_cpu
    core = Core(args.core, disc, args.bios, scratch / args.worker, cpu,
                memory_checkpoints=True, same_binary=True, block_linking=False, inline_gpu=True)
    try:
        state_path = scratch / "state"
        manifest_path = scratch / "manifest.json"
        portable = args.checkpoint == "portable"
        if restoring:
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
                if args.fixture_blank_card:
                    scratch_card(core)[-len(DESTINATION_MARKER):] = DESTINATION_MARKER
                before = core.signature()
                if (load(state, len(state) - 1, disc_hash) or
                        load(state, len(state), bytes(32)) or core.signature() != before):
                    return {"restore_error": "Invalid checkpoint was accepted or changed the guest"}
                if args.fixture_blank_card and not bytes(scratch_card(core)).endswith(DESTINATION_MARKER):
                    return {"restore_error": "Invalid checkpoint changed the destination card"}
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
            if args.fixture_blank_card:
                restored_card = bytes(scratch_card(core))
                if hashlib.sha256(restored_card).hexdigest() != manifest.get("blank_card_sha256"):
                    return {"restore_error": "Restored card is not the blank fixture card"}
                evidence["restored_blank_fixture_card"] = True
        else:
            blank_card = bytes(scratch_card(core)) if args.fixture_blank_card else None
            replay(core, frames[:args.join_frame])
            card = scratch_card(core) if args.fixture_blank_card else None
            started = time.perf_counter()
            if portable:
                payload = export_portable(core, disc_hash, card, blank_card)
            else:
                payload = core.checkpoint().raw
            payload_hash = hashlib.sha256(payload).hexdigest()
            evidence = {
                "capture_ms": round((time.perf_counter() - started) * 1000, 3),
                "checkpoint_bytes": len(payload),
                "checkpoint_sha256": payload_hash,
                "compressed_bytes": len(zlib.compress(payload, level=1)),
                "found_exact_host_disc_path": str(disc).encode("utf-8") in payload,
                "blank_fixture_card": args.fixture_blank_card,
            }
            state_path.write_bytes(payload)
            manifest_path.write_text(json.dumps({
                "identity": local_identity, "frame": args.join_frame, "bytes": len(payload),
                "sha256": payload_hash,
                "blank_card_sha256": hashlib.sha256(blank_card).hexdigest() if blank_card else None,
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
    parser.add_argument("--normalize-host", action="store_true",
                        help="Restore both match peers in the same CPU mode after export")
    parser.add_argument("--match-cpu", choices=CPU_MODES, default="CachedInterpreter",
                        help="CPU mode for peers that restore the checkpoint")
    parser.add_argument("--checkpoint", choices=("portable", "legacy"), default="portable")
    parser.add_argument("--fixture-blank-card", action="store_true",
                        help="Test blank-card export with a synthetic marker on an isolated source card")
    parser.add_argument("--worker", choices=("host", "restored-host", "guest"), help=argparse.SUPPRESS)
    parser.add_argument("--scratch", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.fixture_blank_card and (not args.normalize_host or args.checkpoint != "portable"):
        parser.error("--fixture-blank-card requires portable checkpoints and --normalize-host")
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
        roles = ("host", "restored-host", "guest") if args.normalize_host else ("host", "guest")
        results = {}
        for role in roles:
            subprocess.run([sys.executable, "-B", __file__, *sys.argv[1:], "--worker", role, "--scratch", directory],
                           check=True, timeout=180, stdout=subprocess.DEVNULL)
            results[role] = json.loads((scratch / f"{role}.json").read_text(encoding="utf-8"))
        host, guest = results["host"], results["guest"]
        match_host = results.get("restored-host", host)
        restore_errors = {role: result["restore_error"] for role, result in results.items()
                          if "restore_error" in result}
        mismatch = None if restore_errors else compare(match_host["signatures"], guest["signatures"])
        source_mismatch = None
        if args.normalize_host and not restore_errors:
            keep_cpu = args.host_cpu == args.match_cpu
            source_signatures = host["signatures"] if keep_cpu else host["signatures"][:1]
            resumed_signatures = match_host["signatures"] if keep_cpu else match_host["signatures"][:1]
            source_mismatch = compare(source_signatures, resumed_signatures)
        path_leak = args.checkpoint == "portable" and host["evidence"]["found_exact_host_disc_path"]
        finish_errors = {role: result["finish_error"] for role, result in results.items()
                         if "finish_error" in result}
        report = {
            **host_identity,
            "checkpoint_format": args.checkpoint,
            "host_cpu": args.host_cpu,
            "match_host_cpu": args.match_cpu if args.normalize_host else args.host_cpu,
            "guest_cpu": args.match_cpu,
            "requested_join_frame": args.join_frame,
            "trace_frames": len(frames),
            "matched_checkpoints": len(match_host["signatures"]) if mismatch is None and not restore_errors else None,
            "first_mismatch": mismatch,
            "first_source_mismatch": source_mismatch,
            "restore_error": guest.get("restore_error") or match_host.get("restore_error"),
            "restore_errors": restore_errors,
            "host": host["evidence"],
            "restored_host": results.get("restored-host", {}).get("evidence"),
            "guest": guest.get("evidence"),
            "finish_errors": finish_errors,
            "source_finish": host.get("finish"),
            "finish": guest.get("finish"),
        }
        print(json.dumps(report, indent=2))
        return int(path_leak or bool(restore_errors) or mismatch is not None or source_mismatch is not None
                   or bool(finish_errors) or match_host.get("finish") != guest.get("finish"))


if __name__ == "__main__":
    sys.exit(main())
