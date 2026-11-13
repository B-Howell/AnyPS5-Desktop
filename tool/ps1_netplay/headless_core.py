"""Run one software-only PS1 libretro instance in a dedicated Python process."""
import ctypes as c
import hashlib
import os
import shutil

ENV = c.CFUNCTYPE(c.c_bool, c.c_uint, c.c_void_p)
VIDEO = c.CFUNCTYPE(None, c.c_void_p, c.c_uint, c.c_uint, c.c_size_t)
AUDIO = c.CFUNCTYPE(None, c.c_int16, c.c_int16)
BATCH = c.CFUNCTYPE(c.c_size_t, c.c_void_p, c.c_size_t)
POLL = c.CFUNCTYPE(None)
INPUT = c.CFUNCTYPE(c.c_int16, c.c_uint, c.c_uint, c.c_uint, c.c_uint)
GET_SAVESTATE_CONTEXT = 72 | 0x10000
GET_INPUT_BITMASKS = 51 | 0x10000
JOYPAD_MASK = 256
RUNAHEAD_SAME_INSTANCE = 1
RUNAHEAD_SAME_BINARY = 2
CPU_MODES = ("Recompiler", "CachedInterpreter", "Interpreter")


class Variable(c.Structure):
    _fields_ = [("key", c.c_char_p), ("value", c.c_char_p)]


class GameInfo(c.Structure):
    _fields_ = [("path", c.c_char_p), ("data", c.c_void_p), ("size", c.c_size_t), ("meta", c.c_char_p)]


class Core:
    _checkpoint_active = False
    _checkpoint_context = RUNAHEAD_SAME_INSTANCE

    def __init__(self, dll, disc, bios, root, cpu="Recompiler", *, memory_checkpoints=False,
                 block_linking=True, same_binary=False, inline_gpu=False):
        self.memory_checkpoints = memory_checkpoints
        if same_binary:
            self._checkpoint_context = RUNAHEAD_SAME_BINARY
        root.mkdir()
        system = root / "system"
        save = root / "save"
        system.mkdir()
        save.mkdir()
        shutil.copyfile(bios, system / bios.name)
        self.paths = {9: os.fsencode(system), 19: os.fsencode(dll), 30: os.fsencode(root), 31: os.fsencode(save)}
        self.settings = {}
        self.overrides = {
            b"swanstation_GPU_Renderer": b"Software",
            b"swanstation_GPU_ResolutionScale": b"1",
            b"swanstation_CPU_ExecutionMode": cpu.encode(),
        }
        if not block_linking:
            self.overrides[b"swanstation_CPU_RecompilerBlockLinking"] = b"false"
        if inline_gpu:
            self.overrides[b"swanstation_GPU_UseThread"] = b"false"
        self.frame = 0
        self.pixel = 0
        self.image = None
        self.buttons = (0, 0)
        self.pressed_reads = [0, 0]
        self.hw_requested = False
        c.windll.kernel32.SetErrorMode(0x8003)
        self.previous_directory = os.getcwd()
        os.chdir(root)
        self.dll = c.CDLL(str(dll), winmode=0x1100)
        self.callbacks = [
            ("environment", ENV(self.environment)), ("video_refresh", VIDEO(self.video)),
            ("audio_sample", AUDIO(lambda left, right: None)),
            ("audio_sample_batch", BATCH(lambda data, count: count)),
            ("input_poll", POLL(lambda: None)), ("input_state", INPUT(self.input)),
        ]
        for name, callback in self.callbacks:
            self.bind(f"retro_set_{name}", None, type(callback))(callback)
        if self.bind("retro_api_version", c.c_uint)() != 1:
            raise RuntimeError("Unsupported libretro API")
        self.bind("retro_init", None)()
        self.game = GameInfo(os.fsencode(disc), None, 0, None)
        if not self.bind("retro_load_game", c.c_bool, c.POINTER(GameInfo))(c.byref(self.game)):
            self.bind("retro_deinit", None)()
            raise RuntimeError("Core could not load the game")
        self.step = self.bind("retro_run", None)
        self.ram = self.bind("retro_get_memory_data", c.c_void_p, c.c_uint)(2)
        self.ram_size = self.bind("retro_get_memory_size", c.c_size_t, c.c_uint)(2)
        self.state_size = self.bind("retro_serialize_size", c.c_size_t)()
        self.serialize = self.bind("retro_serialize", c.c_bool, c.c_void_p, c.c_size_t)
        self.unserialize = self.bind("retro_unserialize", c.c_bool, c.c_void_p, c.c_size_t)
        pads = self.bind("retro_set_controller_port_device", None, c.c_uint, c.c_uint)
        for port in range(2):
            pads(port, 1)
        if not self.ram or self.ram_size != 2 * 1024 * 1024 or not 0 < self.state_size <= 64 * 1024 * 1024:
            self.close()
            raise RuntimeError("Expected PS1 main RAM and a bounded save state")
        if any(self.settings.get(key) != value for key, value in self.overrides.items()):
            self.close()
            raise RuntimeError("The requested renderer or CPU options are unavailable")

    def bind(self, name, result, *args):
        fn = getattr(self.dll, name)
        fn.argtypes = args
        fn.restype = result
        return fn

    def environment(self, command, address):
        if command == GET_INPUT_BITMASKS:
            return True
        if command == GET_SAVESTATE_CONTEXT:
            if not self._checkpoint_active:
                return False
            if address is None:
                return True
            self._checkpoint_context_queried = True
            c.cast(address, c.POINTER(c.c_int))[0] = self._checkpoint_context
            return True
        if command in (14, 0x10000 | 14, 0x10000 | 43, 0x10000 | 44):
            self.hw_requested = True
            return False
        if command in (0x10000 | 47, 0x10000 | 49):
            command &= 0xFFFF
        if command in self.paths:
            c.cast(address, c.POINTER(c.c_char_p))[0] = self.paths[command]
            return True
        if command in (3, 17, 49):
            c.cast(address, c.POINTER(c.c_bool))[0] = command == 3
            return True
        if command == 10:
            self.pixel = c.cast(address, c.POINTER(c.c_int))[0]
            return self.pixel in (0, 1, 2)
        if command == 16:
            for row in c.cast(address, c.POINTER(Variable)):
                if not row.key or not row.value:
                    break
                values = row.value.split(b";", 1)[-1].strip().split(b"|")
                selected = self.overrides.get(row.key, values[0])
                self.settings[row.key] = selected if selected in values else values[0]
            return True
        if command == 15:
            row = c.cast(address, c.POINTER(Variable)).contents
            row.value = self.settings.get(row.key)
            return row.value is not None
        if command in (47, 52):
            # Keep video for validation. The headless frontend discards audio.
            c.cast(address, c.POINTER(c.c_uint))[0] = 1 if command == 47 else 0
            return True
        return command in (11, 18, 32, 35, 37)

    def video(self, data, width, height, pitch):
        if not data:
            return
        if data == c.c_void_p(-1).value:
            self.hw_requested = True
            return
        if 0 < height * pitch <= 8 * 1024 * 1024:
            self.image = (width, height, pitch, self.pixel, c.string_at(data, height * pitch))

    def input(self, port, device, index, button):
        if port >= 2 or device != 1 or index != 0:
            return 0
        if button == JOYPAD_MASK:
            mask = self.buttons[port]
            self.pressed_reads[port] += mask.bit_count()
            return c.c_int16(mask).value
        if button >= 16:
            return 0
        pressed = bool(self.buttons[port] & (1 << button))
        if pressed:
            self.pressed_reads[port] += 1
        return int(pressed)

    def advance(self, count, p1, p2):
        self.buttons = (p1, p2)
        for _ in range(count):
            self.step()
            self.frame += 1
            if self.hw_requested:
                raise RuntimeError("A hardware context was requested in a software-only run")

    def read_ram(self, offset=0, length=None):
        length = self.ram_size if length is None else length
        if not 0 <= offset <= offset + length <= self.ram_size:
            raise ValueError("RAM read outside the system RAM")
        return c.string_at(self.ram + offset, length)

    def signature(self):
        return self.hash_signature(self.frame, self.signature_snapshot())

    def signature_snapshot(self):
        return self.read_ram(), self.image

    @staticmethod
    def hash_signature(frame, snapshot):
        ram, image = snapshot
        video_hash = None
        if image is not None:
            width, height, pitch, pixel, raw = image
            row_bytes = width * (4 if pixel == 1 else 2)
            visible = b"".join(raw[i:i + row_bytes] for i in range(0, height * pitch, pitch))
            video_hash = hashlib.sha256(f"{width},{height},{pixel}:".encode() + visible).hexdigest()
        return {"frame": frame, "ram": hashlib.sha256(ram).hexdigest(), "video": video_hash}

    def checkpoint(self, buffer=None):
        if buffer is None:
            buffer = c.create_string_buffer(self.state_size)
        if not isinstance(buffer, c.Array) or buffer._type_ is not c.c_char or len(buffer) != self.state_size:
            raise ValueError("Expected a writable checkpoint buffer matching the core's state size")
        if not self._checkpoint_call(self.serialize, buffer, self.state_size):
            raise RuntimeError("Core rejected serialization")
        return buffer

    def restore(self, frame, state, image=None):
        if not self._checkpoint_call(self.unserialize, state, len(state)):
            raise RuntimeError("Core rejected checkpoint")
        if self.memory_checkpoints and not self._checkpoint_context_queried:
            raise RuntimeError("Core ignored the requested save-state context")
        self.frame = frame
        self.image = image

    def _checkpoint_call(self, operation, data, size):
        self._checkpoint_context_queried = False
        self._checkpoint_active = self.memory_checkpoints
        try:
            return operation(data, size)
        finally:
            self._checkpoint_active = False

    def close(self):
        self.bind("retro_unload_game", None)()
        self.bind("retro_deinit", None)()
        os.chdir(self.previous_directory)
