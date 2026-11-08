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

## Simulated network trial

The [rollback harness](../tool/ps1_netplay/rollback.py) uses the same pinned
inputs and the offline run's per-frame RAM and video hashes. It starts two
isolated software workers. Each worker knows its own input tape and only
receives the other port's inputs through a seeded virtual link. There is no
socket between the processes. The link sends one packet per virtual 60 Hz
tick with up to 16 recent inputs. It delays, drops and reorders packets by
the selected profile. Each direction uses a different seed.

The default trial uses two ticks of local input delay and an eight-frame
prediction window. On missing input, a worker holds the latest known remote
mask from before the predicted frame. A late correction restores the
checkpoint before the earliest mismatched frame and replays to the prior
tip. The worker stalls when its outstanding frames reach the window and
can advance at most two new frames per tick to catch up. The test compares
every newly confirmed frame against the offline control, checks the game
finish and refuses to count predictions beyond an unfilled gap. Window zero
waits for confirmed input and serves as the lockstep control.

After the offline command above, use its `worker-1/run.json` as the baseline.
The enclosing `summary.json` must identify the same fixture and the worker
must have a signature for every frame. Use a fresh output directory per
trial.

```powershell
python -B tool/ps1_netplay/rollback.py `
  --core "$core" --disc "$cue" --bios "$bios" --output "$trial" `
  --trace tool/ps1_netplay/fixtures/ctr_usa_coco_park_versus.json `
  --baseline "$output/worker-1/run.json" --profile 80ms-loss
```

Use `--window 0` for the corresponding lockstep control. The profiles use
nominal round-trip times. Each one-way delivery rounds up to a virtual tick.
For example, 20 ms one way arrives after two ticks, so the nominal 40 ms
profile has an effective four-tick round trip in this model. `80ms-jitter`
uses ±15 ms one-way jitter. `80ms-loss` adds 2% random loss and a seven-tick
burst. `120ms-loss` uses ±25 ms jitter, 5% random loss and a ten-tick burst.

The [rollback unit tests](../tool/ps1_netplay/test_rollback.py) exercise
correction, reordering, loss, lockstep, a missing frame older than the packet
history, and a deliberately incorrect baseline. The per-peer receipt tracks
replays, maximum depth, checkpoint payload, stall counts and longest stall.
Input scheduling delay is the virtual time until first simulation, including
the configured input buffer. The harness separately measures elapsed host
work for save, restore and emulation steps, including callback copies. Hashing
and network simulation are outside that timer. Elapsed work can exceed the
16.67 ms frame budget without slowing the virtual clock. These figures do
not measure actual controller-to-display latency, audio quality, WAN play or
native launcher performance.

### Original DLL controls

Both peers matched all 13,706 frames at zero delay and at the nominal
40 ms profile. The latter never needed a rewind with the two-tick buffer.
At 80 ms with jitter, the first divergent frames were 5,624 and 1,114.
At 80 and 120 ms with loss, they were 5,759 and 1,114. The first differences
were in RAM while the video hash still matched. With prediction disabled,
both peers finished under both loss profiles. Lockstep waited on 3,844–3,966
ticks at 80 ms and 4,559–4,601 ticks at 120 ms.

Reproducing the frame-1,114 difference did not require packet faults. In
the recompiler mode, a save followed immediately by a restore at frame
600 or 602 led to the same first mismatch under the same input trace.
The packet trial differed in three RAM bytes at that frame. An
uninterrupted control matched. The interpreter passed that
short restore probe. This isolates a restore-sensitive difference in the
tested recompiler configuration. It does not identify an internal core
mechanism or make the differing RAM bytes safe to ignore.

Increasing the buffer to four ticks at 80 ms with loss still produced a
confirmed mismatch for one peer at frame 5,601. At 120 ms with loss, a
six-tick buffer kept both peers matched through the full race with seeds
2401 and 2405. Each peer rewound once per seed. The p95 simulated local
input delay was six ticks (100 ms), and each correction took 34.7–81.8 ms
of measured work. That qualifies synchronization in those trials, with
substantial delay and occasional work exceeding the frame budget.

### Original DLL interpreter control

The [interpreter trace](../tool/ps1_netplay/fixtures/ctr_usa_coco_park_interpreter.json)
is a separately recorded controller-only race on the same track. The
recompiler input tape did not finish a two-player race in interpreter mode,
so it is unsuitable as a full-race interpreter fixture. Two cold interpreter
runs matched all 14,175 frames of the new trace and finished with Crash
first after three laps. To reproduce, use the interpreter trace in both
commands and pass `--cpu Interpreter`. Use a new baseline output and omit
the original race's checkpoint arguments. The worker verifies that the CPU
mode and other effective options match the baseline.

The interpreter did not fix full-race rollback. With a two-tick buffer,
both peers diverged in RAM at frame 6,458 in the 80 ms loss trial. In the
120 ms loss trial, the first differences were at frames 6,458 and 6,386.
Video matched at those first differing frames. The short same-trace
restore probe remains the controlled CPU-mode comparison. The full races
used different controller tapes and establish the limits of each tested
configuration.

### Checkpoint restore fix

The rollback workers now request Libretro's `RUNAHEAD_SAME_INSTANCE`
save-state context during checkpoint calls. Each worker only restores states
it created in its own live core. The original DLL uses its in-memory restore
path for this context. Its `ROLLBACK_NETPLAY` context still takes the
file-style path, as does the offline harness by default. In a no-network
test, an immediate restore at frame 600 reproduced the RAM mismatch at
frame 1,114 with the file-style contexts. The same-instance restore matched
through frame 1,200.

The original DLL still failed a real rewind with the same-instance context.
Save after frame 1,662, advance one frame using the correct recorded inputs,
then restore and replay. The original DLL changed the restored sound unit
(SPU) tick carry from 83 to 353 when the intervening frame changed the sample
interval. The next replayed frame changed the SPU timer phase by 270 CPU
cycles. Main RAM first differed at frame 1,664. Restoring immediately after
saving at 1,662 did not reproduce this failure.

The [SwanStation SPU checkpoint patch](../tool/patches/swanstation-spu-checkpoint.patch)
removes the sample event reschedule from `SPU::DoState`. That reschedule could
execute the live timeline's sample timer against the checkpoint's restored
SPU state. The sample event stays active and `TimingEvents::DoState` restores
its saved timing. The separate SPU transfer event is still reconstructed.
The patch is for the standalone test core and can be reproduced from
[SwanStation `631f0fb31b809e0f889d7c551fe695788e39c1d3`](https://github.com/libretro/swanstation/tree/631f0fb31b809e0f889d7c551fe695788e39c1d3).
From an x64 Visual Studio developer shell with CMake and Ninja, run these
commands from the Desktop worktree. Choose a fresh directory outside this
worktree for `$coreSource`.

```powershell
$patch = (Resolve-Path tool/patches/swanstation-spu-checkpoint.patch).Path
git clone https://github.com/libretro/swanstation.git "$coreSource"
git -C "$coreSource" checkout --detach 631f0fb31b809e0f889d7c551fe695788e39c1d3
git -C "$coreSource" apply --check "$patch"
git -C "$coreSource" apply "$patch"
cmake -S "$coreSource" -B "$coreSource/build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "$coreSource/build" --parallel 4
$core = "$coreSource/build/swanstation_libretro.dll"
```

Generate a fresh two-worker offline baseline using the patched DLL before
running the network profiles. The rollback tool binds its baseline to the
DLL hash. The locally built DLL had SHA-256
`edf09b2188eec014eafbb4653ab0ddb6d8eb026a483057738a0740a57c436994`.
Both cold runs matched the original DLL's 13,706 frame signatures, effective
options and finish result. A targeted comparison between unmodified and
patched local builds reproduced the tick carry change only with the
unmodified build. Seat 2 also passed the first 1,680 frames of the 80 ms
loss trace on the patched build with the same three rewinds as the red run.

### Patched full-race trials

Each profile used the recompiler, `--delay 2 --window 8 --seed 2401`, and
one worker per controller port. Both workers confirmed all 13,706 frames
against the patched offline baseline and produced the original placements.
Cortex finished first after three laps and Crash was placed second. The
table gives each peer's results in port order.

| Profile | Corrections | Simulated stalls | p95 input delay in ticks | p95 host work in ms | Host work ticks over 16.67 ms |
| --- | --- | --- | --- | --- | --- |
| 80 ms with jitter | 504 / 1,043 | 0 / 0 | 2 / 2 | 10.93 / 19.64 | 526 / 961 |
| 80 ms with jitter and loss | 493 / 1,029 | 0 / 0 | 2 / 2 | 8.98 / 20.97 | 493 / 985 |
| 120 ms with jitter and loss | 669 / 1,348 | 5 / 5 | 2 / 2 | 11.93 / 25.76 | 675 / 1,330 |

Two virtual ticks are about 33.3 ms of input scheduling delay. These
trials qualify synchronization under the tested packet schedules. Some
replay work exceeds a real 60 Hz frame budget. Each peer's maximum
virtual input delay at 120 ms was seven ticks. Native rendering, audio, physical input latency,
and two-PC play still need measurement. File-style loads share the SPU
fix. Legacy saves and loads across different core settings were outside
this experiment.
