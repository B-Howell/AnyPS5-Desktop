"""Compare two independent PS2 processes restored from one normal checkpoint.

Windows software-renderer qualification only. This setup-menu trace is not a
multiplayer match. The opaque checkpoint contains game memory: keep output private.
"""
import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from checkpoint import CheckpointCore, SEQUENCE, compare, digest, state_difference, validate_fixture, wait_owned


def pins(fixture):
    return {key + "Sha256": fixture[key + "Sha256"] for key in ("core", "disc", "bios", "card")}


def validate_seed(metadata, data, fixture):
    if (not isinstance(metadata, dict) or metadata.get("schema") != 1 or
            not isinstance(metadata.get("bytes"), int) or not 0 < metadata["bytes"] <= 256 * 1024**2 or
            metadata["bytes"] != len(data) or metadata.get("pins") != pins(fixture) or
            metadata.get("sha256") != hashlib.sha256(data).hexdigest()):
        raise ValueError("Checkpoint size, hash, schema or fixture pins do not match")


def compare_peers(host, guest):
    result = {"hostRamMatchesSeed": host["ramMatchesSeed"], "guestRamMatchesSeed": guest["ramMatchesSeed"],
              "hostStateMatchesSeed": host["serialized"]["matches"],
              "guestStateMatchesSeed": guest["serialized"]["matches"],
              "mismatches": compare(host["samples"], guest["samples"])}
    result["passed"] = all(result[key] for key in ("hostRamMatchesSeed", "guestRamMatchesSeed",
                                                   "hostStateMatchesSeed", "guestStateMatchesSeed")) and not result["mismatches"]
    return result


def worker(args, fixture):
    role = args.worker
    root = args.output / role
    root.mkdir()
    for name in ("system/pcsx2/bios", "system/pcsx2/memcards", "saves"):
        (root / name).mkdir(parents=True, exist_ok=True)
    shutil.copyfile(fixture["bios"], root / "system/pcsx2/bios/fixture.bin")
    shutil.copyfile(fixture["card"], root / "system/pcsx2/memcards/Mcd001.ps2")
    metadata = raw = None
    if role != "donor":
        if (args.output / "seed.json").stat().st_size > 16384 or (args.output / "seed.bin").stat().st_size > 256 * 1024**2:
            raise ValueError("Checkpoint files exceed the bounds")
        metadata = json.loads((args.output / "seed.json").read_text(encoding="utf-8"))
        raw = (args.output / "seed.bin").read_bytes()
        validate_seed(metadata, raw, fixture)
    core = CheckpointCore(fixture, root, 0, "Recompiler")
    try:
        boot_ticks = args.guest_boot if role == "guest" and args.guest_boot is not None else args.boot
        core.advance(boot_ticks, 0, 0)
        if role == "donor":
            state = core.checkpoint()
            if not core._checkpoint_context_queried:
                raise RuntimeError("Core ignored the checkpoint context")
            (args.output / "seed.bin").write_bytes(state)
            metadata = {"schema": 1, "bytes": len(state), "sha256": digest(args.output / "seed.bin"),
                        "ram": hashlib.sha256(core.read_ram()).hexdigest(), "pins": pins(fixture),
                        "bootTicks": args.boot, "settings": {key.decode(): value.decode() for key, value in core.settings.items()}}
            (args.output / "seed.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
            print(json.dumps({"role": role, "stateBytes": len(state)}), flush=True)
            return 0
        if metadata["settings"] != {key.decode(): value.decode() for key, value in core.settings.items()}:
            raise ValueError("Core options differ from the checkpoint producer")
        state = c.create_string_buffer(raw, len(raw))
        core.restore(metadata["bootTicks"], state)
        restored_ram = hashlib.sha256(core.read_ram()).hexdigest()
        serialized = state_difference(state, core.checkpoint())
        samples = core.trace(args.blocks)
        receipt = {"role": role, "bootTicks": boot_ticks, "ramMatchesSeed": restored_ram == metadata["ram"],
                   "serialized": serialized, "samples": samples, "pins": pins(fixture)}
        (root / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
        print(json.dumps({key: value for key, value in receipt.items() if key not in ("samples", "pins")}), flush=True)
        return 0
    finally:
        core.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New private directory on D:")
    parser.add_argument("--boot", type=int, default=3100)
    parser.add_argument("--guest-boot", type=int, help="Use a different guest boot history before restoring the donor state")
    parser.add_argument("--blocks", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=120, help="Deadline for each sequential worker")
    parser.add_argument("--worker", choices=("donor", "host", "guest"), help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.fixture, args.output = args.fixture.resolve(), args.output.resolve()
    if sys.platform != "win32" or args.output.drive.upper() != "D:":
        parser.error("The native qualification currently requires Windows and private output on D:")
    if not 1 <= args.boot <= 10000 or not 2 <= args.blocks <= 60 or not 1 <= args.timeout <= 300:
        parser.error("Use 1..10000 boot ticks, 2..60 replay blocks and a 1..300 second deadline")
    if args.guest_boot is not None and not 1 <= args.guest_boot <= 10000:
        parser.error("Guest boot history must be 1..10000 ticks")
    fixture = json.loads(args.fixture.read_text(encoding="utf-8-sig"))
    validate_fixture(fixture)
    if args.worker:
        return worker(args, fixture)
    if shutil.disk_usage("C:/").free < 310 * 1024**3 or shutil.disk_usage("D:/").free < 15 * 1024**3:
        parser.error("Storage guard requires C: >=310 GiB and D: >=15 GiB free")
    args.output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, TEMP=str(args.output), TMP=str(args.output), PYTHONDONTWRITEBYTECODE="1")
    receipt = {"schema": 1, "pins": pins(fixture), "bootTicks": args.boot,
               "guestBootTicks": args.guest_boot if args.guest_boot is not None else args.boot, "replayTicks": args.blocks * 60,
               "inputSequence": SEQUENCE, "ramSamplingTicks": 60, "workers": [],
               "sourceSha256": digest(Path(__file__)),
               "checkpointSourceSha256": digest(Path(__file__).with_name("checkpoint.py")),
               "abiSourceSha256": digest(Path(__file__).resolve().parents[1] / "ps1_netplay/headless_core.py")}
    try:
        for role in ("donor", "host", "guest"):
            command = [sys.executable, "-B", str(Path(__file__).resolve()), "--fixture", str(args.fixture),
                       "--output", str(args.output), "--boot", str(args.boot), "--blocks", str(args.blocks), "--worker", role]
            if args.guest_boot is not None:
                command += ["--guest-boot", str(args.guest_boot)]
            with (args.output / f"{role}.out").open("w") as out, (args.output / f"{role}.err").open("w") as err:
                process = subprocess.Popen(command, stdout=out, stderr=err, env=env,
                                           creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS)
                result = wait_owned(process, args.timeout)
            receipt["workers"].append({"role": role, "exit": result})
            print(json.dumps({"role": role, "exit": result}), flush=True)
            if result:
                return result
        host = json.loads((args.output / "host/receipt.json").read_text(encoding="utf-8"))
        guest = json.loads((args.output / "guest/receipt.json").read_text(encoding="utf-8"))
        receipt["comparison"] = compare_peers(host, guest)
        print(json.dumps(receipt["comparison"]), flush=True)
        return 0 if receipt["comparison"]["passed"] else 3
    except BaseException as error:
        receipt["failure"] = type(error).__name__
        raise
    finally:
        receipt["fixtureUnchanged"] = False
        try:
            validate_fixture(fixture)
            receipt["fixtureUnchanged"] = True
        finally:
            (args.output / "comparison.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
