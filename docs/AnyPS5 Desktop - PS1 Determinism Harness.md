# AnyPS5 Desktop PS1 determinism harness

This local tool compares independent SwanStation processes on Windows. The
[coordinator](../tool/ps1_netplay/determinism.py) runs at most two workers
at once. Each [worker](../tool/ps1_netplay/headless_core.py) loads the same
pinned Libretro DLL, uses its own temporary system and save directories,
and feeds controller snapshots directly to both ports. It requires 1×
software rendering, refuses hardware contexts, discards audio, and starts
with no window. It never opens an AnyPS5 launcher or connects to a service.

The [Coco Park Versus fixture](../tool/ps1_netplay/fixtures/ctr_usa_coco_park_versus.json)
contains only run-length encoded controller inputs. Each entry is a count
of emulation frames and the two digital RetroPad button masks. The trace
starts at cold boot and ends at the result screen. An offscreen driver
generated the masks by reading checkpoint positions and kart telemetry
from the game and steering through ordinary input callbacks. It never
wrote game RAM. The optional CTR finish check uses the USA retail layout
to read the end-of-race flag, player count, lap count and final placements.
It is gated by the canonical CUE digest. [CTR decompilation reference](https://github.com/CTR-tools/CTR-ModSDK/tree/e3f19686)

## Reproduce on Windows

Use Python 3.11 or newer, a local USA Crash Team Racing CUE/BIN, a local PS1
BIOS and the verified SwanStation DLL. Substitute your local paths. The
output directory must be new and outside the repository. Worker folders
contain private BIOS copies and any temporary saves.

```powershell
python -B -m unittest discover -s tool/ps1_netplay -v
python -B tool/ps1_netplay/determinism.py `
  --core "$core" --disc "$cue" --bios "$bios" --output "$output" `
  --trace tool/ps1_netplay/fixtures/ctr_usa_coco_park_versus.json `
  --runs 3 --interval 1 --ctr-finish `
  --replay 6500:6508 --replay 9000:9016 --replay 12000:12032
```

The [unit suite](../tool/ps1_netplay/test_determinism.py) covers CUE identity,
trace validation, first-divergence reporting and the game-owned finish
predicate. The real harness compares main RAM and the visible framebuffer
on every sampled emulation frame. It compares the last displayed
frame when Libretro repeats a frame. Replays restore the worker's own
checkpoint and displayed frame, run the same inputs and compare their end
state with the uninterrupted pass. Whole save-state blobs can include host
metadata. Use the RAM and framebuffer fingerprints as the measured
evidence, and retain the state only for replay.

| Input | SHA-256 |
| --- | --- |
| SwanStation DLL | `1aaa621dab9f53b130ac29d17e9a12ea4c0df975d4b02b53faec3b52c717fd12` |
| Canonical USA CUE/track identity | `7061d0d774c4d73bd3bc90afaa1b6d35a9fcdd797c5d92d973af55423e2ce59f` |
| SCPH1001 BIOS | `71af94d1e47a68c11e8fdb9f8368040601514a42a5a399cda48c7d3bff1e99d3` |
| Two-player trace | `1ebe8ea9404caae28caec484e2bd1dc2b0fd7c67c47fcb8810aad6667e59d9c6` |

## Local race result

Three independent cold runs on the same Windows PC matched at all 13,706
sampled emulation frames. The first two ran concurrently. The race ended
at frame 13,346 with Cortex on port 2 first after three laps. The game ended
the Versus match and placed Crash on port 1 second while he was on the final
lap. Every worker read 10,412 pressed inputs on port 1 and 10,272 on port 2.
The finish predicate confirmed the same placements in all three workers.

All nine restore-and-replay checks matched their own uninterrupted endpoint.
They replayed 8, 16 and 32 frames at different points during the race. The
core returned an 11 MiB serialization buffer. Saves took 3.5–4.0 ms, restores
8.0–15.7 ms, and eight-frame replay alone took 45.6–52.0 ms in this Python
harness. A negative control replaced port 2's input on frames 6,001–6,060.
The first RAM or framebuffer difference was detected at frame 6,001.

## Evidence boundary

The qualification covers one Windows PC and one software core configuration
with a fixed disc, BIOS and blank save profile. The concurrent workers
consume the same recorded inputs from local files. No network transport,
hardware renderer or cross-machine behavior is qualified. Timing from
the replay harness includes host work and concurrency effects. It is a
diagnostic, not a latency benchmark or a rollback frame budget.
