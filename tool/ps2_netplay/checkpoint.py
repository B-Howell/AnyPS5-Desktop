"""Isolated Windows PS2 checkpoint/replay qualification; never opens a window.

This is a core diagnostic, not a multiplayer implementation or a gameplay proof.
Run --help for the pinned fixture and scratch-directory contract.
"""
import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ps1_netplay"))
from headless_core import Core, GameInfo, ENV, VIDEO, AUDIO, BATCH, POLL, INPUT

SEQUENCE = [(0, 0), (1 << 8, 1 << 7), (0, 0), (1 << 6, 1 << 4),
            (0, 0), (1 << 7, 1 << 5), (0, 0), (0, 0)]


def wait_owned(process, timeout):
    try:
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return 124
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_fixture(fixture):
    for key in ("core", "disc", "bios", "card"):
        pin = fixture.get(key + "Sha256", "")
        if not fixture.get(key) or len(pin) != 64 or any(ch not in "0123456789abcdef" for ch in pin):
            raise ValueError(f"Expected {key} and its lowercase SHA-256 pin")
        if digest(fixture[key]) != pin:
            raise ValueError(f"{key} SHA-256 does not match the fixture")


def compare(before, after):
    if not before or len(before) != len(after):
        raise ValueError("Expected equally sized, nonempty replay traces")
    mismatches = []
    for index, (left, right) in enumerate(zip(before, after)):
        fields = [key for key in ("step", "ram", "video", "audio", "videoFrames", "audioFrames", "inputReads")
                  if left[key] != right[key]]
        for sample in (left, right):
            for field, missing in (("videoMissing", not sample["video"] or not sample["videoFrames"]),
                                   ("audioMissing", not sample["audioFrames"]),
                                   ("inputMissing", index == len(before) - 1 and not all(sample["inputReads"]))):
                if missing and field not in fields:
                    fields.append(field)
        if fields:
            mismatches.append({"step": index, "fields": fields})
    return mismatches


def state_difference(before, after):
    """Compare serialized buffers without copying them or writing game memory."""
    left, right = memoryview(before).cast("B"), memoryview(after).cast("B")
    matches = left == right
    offsets = []
    if not matches:
        # Skip equal pages in native memoryview comparisons, rather than
        # visiting tens of millions of matching bytes in Python.
        for start in range(0, max(len(left), len(right)), 4096):
            a, b = left[start:start + 4096], right[start:start + 4096]
            if a == b:
                continue
            for index in range(max(len(a), len(b))):
                if index >= min(len(a), len(b)) or a[index] != b[index]:
                    offsets.append(start + index)
                    if len(offsets) == 64:
                        break
            if len(offsets) == 64:
                break
    return {"matches": matches, "beforeBytes": len(left), "afterBytes": len(right), "firstOffsets": offsets}


class CheckpointCore(Core):
    """Reuse the PS1 probe's libretro ABI, bounds checks and digital input.

    PS2 has different firmware paths, RAM bounds and options. Hardware contexts
    are refused: CPU-visible software frames avoid a GPU cache/readback confound.
    """
    def __init__(self, fixture, root, context, cpu):
        self.previous_directory = os.getcwd()
        self.loaded = self.initialized = False
        self._checkpoint_active = False
        self._checkpoint_context = context
        self.memory_checkpoints = True
        self.buttons = (0, 0)
        self.pressed_reads = [0, 0]
        self.frame = self.video_frames = self.audio_frames = 0
        self.image = None
        self.pixel = 0
        self.hw_requested = False
        self.audio_hash = hashlib.sha256()
        self.video_hash = hashlib.sha256()
        self.settings = {}
        self.overrides = {b"pcsx2_renderer": b"Software (SW)",
                          b"pcsx2_dev9_eth": b"disabled", b"pcsx2_fastboot": b"enabled",
                          b"pcsx2_ee_cpu": cpu.encode(), b"pcsx2_mtvu": b"disabled"}
        self.paths = {9: os.fsencode(root / "system"), 19: os.fsencode(fixture["core"]),
                      30: os.fsencode(root), 31: os.fsencode(root / "saves")}
        os.chdir(root)
        c.windll.kernel32.SetErrorMode(0x8003)
        try:
            self.dll = c.CDLL(str(Path(fixture["core"]).resolve()), winmode=0x1100)
            self.callbacks = [("environment", ENV(self.environment)), ("video_refresh", VIDEO(self.video)),
                              ("audio_sample", AUDIO(self.audio)), ("audio_sample_batch", BATCH(self.batch)),
                              ("input_poll", POLL(lambda: None)), ("input_state", INPUT(self.input))]
            for name, callback in self.callbacks:
                self.bind(f"retro_set_{name}", None, type(callback))(callback)
            if self.bind("retro_api_version", c.c_uint)() != 1:
                raise RuntimeError("Unsupported libretro API")
            self.bind("retro_init", None)()
            self.initialized = True
            self.game = GameInfo(os.fsencode(fixture["disc"]), None, 0, None)
            self.loaded = self.bind("retro_load_game", c.c_bool, c.POINTER(GameInfo))(c.byref(self.game))
            if not self.loaded:
                raise RuntimeError("Core refused game")
            self.step = self.bind("retro_run", None)
            self.serialize = self.bind("retro_serialize", c.c_bool, c.c_void_p, c.c_size_t)
            self.unserialize = self.bind("retro_unserialize", c.c_bool, c.c_void_p, c.c_size_t)
            self.ram = self.bind("retro_get_memory_data", c.c_void_p, c.c_uint)(2)
            self.ram_size = self.bind("retro_get_memory_size", c.c_size_t, c.c_uint)(2)
            self.state_size = self.bind("retro_serialize_size", c.c_size_t)()
            if not self.ram or not 32 * 1024 * 1024 <= self.ram_size <= 64 * 1024 * 1024:
                raise RuntimeError("Expected bounded PS2 main RAM")
            if not 0 < self.state_size <= 256 * 1024 * 1024:
                raise RuntimeError("Expected bounded PS2 checkpoint")
            if any(self.settings.get(key) != value for key, value in self.overrides.items()):
                raise RuntimeError("Requested core options unavailable")
        except BaseException:
            self.close()
            raise

    def environment(self, command, address):
        if command == (47 | 0x10000) and address:
            c.cast(address, c.POINTER(c.c_uint))[0] = 3
            return True
        return super().environment(command, address)

    def video(self, data, width, height, pitch):
        super().video(data, width, height, pitch)
        if data and data != c.c_void_p(-1).value and self.image is not None and 0 < height * pitch <= 8 * 1024 * 1024:
            self.video_frames += 1
            row_bytes = width * (4 if self.pixel == 1 else 2)
            self.video_hash.update(struct.pack("<III", width, height, self.pixel))
            raw = self.image[-1]
            for y in range(height):
                self.video_hash.update(raw[y * pitch:y * pitch + row_bytes])

    def audio(self, left, right):
        self.audio_frames += 1
        self.audio_hash.update(struct.pack("<hh", left, right))

    def checkpoint(self, buffer=None):
        # GS initialization can grow the state after retro_load_game. A size
        # cached before the first run silently selects the core's normal restore
        # fallback even when the frontend requests same-instance context.
        self.state_size = self.bind("retro_serialize_size", c.c_size_t)()
        if not 0 < self.state_size <= 256 * 1024 * 1024:
            raise RuntimeError("Expected bounded PS2 checkpoint")
        return super().checkpoint(buffer)

    def batch(self, data, count):
        self.audio_frames += count
        self.audio_hash.update(c.string_at(data, count * 4))
        return count

    def trace(self, blocks):
        self.audio_hash = hashlib.sha256()
        self.video_hash = hashlib.sha256()
        self.video_frames = self.audio_frames = 0
        self.pressed_reads = [0, 0]
        result = []
        # Exercise both ports; callback reads do not prove the game
        # accepted a button, entered multiplayer, or responded in gameplay.
        for index in range(blocks):
            self.advance(60, *SEQUENCE[index % len(SEQUENCE)])
            signature = self.signature()
            result.append({"step": index, "ram": signature["ram"],
                           "video": self.video_hash.hexdigest() if self.video_frames else None,
                           "audio": self.audio_hash.hexdigest(), "videoFrames": self.video_frames,
                           "audioFrames": self.audio_frames, "inputReads": list(self.pressed_reads)})
        return result

    def close(self):
        try:
            if self.loaded:
                self.loaded = False
                self.bind("retro_unload_game", None)()
        finally:
            try:
                if self.initialized:
                    self.initialized = False
                    self.bind("retro_deinit", None)()
            finally:
                os.chdir(self.previous_directory)


def worker(args, fixture):
    def phase(name):
        (args.output / "progress.json").write_text(json.dumps({"phase": name}), encoding="utf-8")

    phase("prepare")
    profile = args.output / "profile"
    profile.mkdir()
    for name in ("system/pcsx2/bios", "system/pcsx2/memcards", "saves"):
        (profile / name).mkdir(parents=True, exist_ok=True)
    shutil.copyfile(fixture["bios"], profile / "system/pcsx2/bios/fixture.bin")
    shutil.copyfile(fixture["card"], profile / "system/pcsx2/memcards/Mcd001.ps2")
    core = CheckpointCore(fixture, profile, int(args.context == "same-instance"), args.cpu)
    try:
        phase("boot")
        core.advance(args.boot, 0, 0)
        phase("capture")
        start = time.perf_counter()
        state = core.checkpoint()
        save_ms = (time.perf_counter() - start) * 1000
        if not core._checkpoint_context_queried:
            raise RuntimeError("Core ignored the save-state context")
        initial_ram = hashlib.sha256(core.read_ram()).hexdigest()
        frame = core.frame
        image = core.image
        phase("first-trace")
        before = core.trace(args.blocks)
        phase("restore")
        start = time.perf_counter()
        core.restore(frame, state, image)
        load_ms = (time.perf_counter() - start) * 1000
        restored_ram = hashlib.sha256(core.read_ram()).hexdigest()
        restored_state = None
        if args.inspect_state:
            phase("inspect-restored-state")
            restored_state = state_difference(state, core.checkpoint())
        phase("replay")
        after = core.trace(args.blocks)
        mismatches = compare(before, after)
        receipt = {"schema": 1, "inputSequence": SEQUENCE, "ramSamplingTicks": 60,
                   "videoCoverage": "all nonduplicate software video callbacks",
                   "sourceSha256": digest(Path(__file__)),
                   "abiSourceSha256": digest(Path(__file__).resolve().parents[1] / "ps1_netplay/headless_core.py"),
                   "context": args.context, "cpu": args.cpu, "bootTicks": args.boot,
                   "replayTicks": args.blocks * 60, "stateBytes": len(state),
                   "saveMs": save_ms, "loadMs": load_ms, "sameRamAtRestore": initial_ram == restored_ram,
                   "restoredState": restored_state,
                   "before": before, "after": after, "mismatches": mismatches,
                   "pins": {key: value for key, value in fixture.items() if key.endswith("Sha256")},
                   "settings": {key.decode(): value.decode() for key, value in core.settings.items()}}
        (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
        phase("compared")
        print(json.dumps({key: receipt[key] for key in ("context", "saveMs", "loadMs", "sameRamAtRestore", "restoredState", "mismatches")}), flush=True)
        return 0 if (initial_ram == restored_ram and not mismatches and
                     (restored_state is None or restored_state["matches"])) else 3
    finally:
        core.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True, help="JSON: core/disc/bios/card paths and each <key>Sha256")
    parser.add_argument("--output", type=Path, required=True, help="New scratch directory on D:; never a game/profile directory")
    parser.add_argument("--context", choices=("normal", "same-instance"), default="normal")
    parser.add_argument("--cpu", choices=("Recompiler", "Interpreter"), default="Recompiler")
    parser.add_argument("--boot", type=int, default=3100)
    parser.add_argument("--blocks", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--inspect-state", action="store_true", help="Normal context only: reserialize after restore and compare the entire state; this adds a diagnostic capture")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inspect_state and args.context != "normal":
        parser.error("Serialized-state inspection is only supported in normal context")
    if sys.platform != "win32":
        parser.error("The native probe currently supports Windows only")
    args.fixture = args.fixture.resolve()
    args.output = args.output.resolve()
    if args.output.drive.upper() != "D:" or not 1 <= args.boot <= 10000 or not 1 <= args.blocks <= 60 or not 1 <= args.timeout <= 300:
        parser.error("Use D: output, 1..10000 boot ticks, 1..60 replay blocks and 1..300 seconds")
    fixture = json.loads(args.fixture.read_text(encoding="utf-8-sig"))
    validate_fixture(fixture)
    fixture = {key: str(Path(value).resolve()) if key in ("core", "disc", "bios", "card") else value
               for key, value in fixture.items()}
    if args.worker:
        return worker(args, fixture)
    if shutil.disk_usage("C:/").free < 310 * 1024**3 or shutil.disk_usage("D:/").free < 15 * 1024**3:
        parser.error("Storage guard requires C: >=310 GiB and D: >=15 GiB free")
    args.output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, TEMP=str(args.output), TMP=str(args.output), PYTHONDONTWRITEBYTECODE="1")
    command = [sys.executable, "-B", str(Path(__file__).resolve()), *sys.argv[1:], "--worker"]
    result = None
    failure = None
    try:
        with (args.output / "worker.out").open("w") as out, (args.output / "worker.err").open("w") as err:
            process = subprocess.Popen(command, stdout=out, stderr=err, env=env,
                                       creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS)
            result = wait_owned(process, args.timeout)
    except BaseException as error:
        failure = type(error).__name__
        raise
    finally:
        # Original fixtures are read-only inputs. Even a failed probe must leave
        # their hashes unchanged; all core writes belong to the new D: profile.
        unchanged = False
        try:
            validate_fixture(fixture)
            unchanged = True
        finally:
            (args.output / "process-receipt.json").write_text(json.dumps({
                "exit": result, "failure": failure, "fixtureUnchanged": unchanged,
                "sourceSha256": digest(Path(__file__)), "timeoutSeconds": args.timeout,
            }, indent=2), encoding="utf-8")
    print(json.dumps({"exit": result, "output": str(args.output), "fixtureUnchanged": True}))
    return result


if __name__ == "__main__":
    raise SystemExit(main())
