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

### Reducing correction work

In a 6,400-frame 120 ms loss probe, median checkpoint time was 3.99 ms,
including 1.09 ms in `retro_serialize`. The [headless core](../tool/ps1_netplay/headless_core.py)
now serializes directly into a writable buffer and passes that buffer back
to the core on restore. The [rollback worker](../tool/ps1_netplay/rollback.py)
reuses at most one buffer per frame of its prediction window. The live
checkpoints span at most one window beyond the confirmed frontier. Replay
reads a checkpoint before it can overwrite that slot. The same probe with
buffer reuse measured 1.19 ms median checkpoint time.

Native timing showed repeated code-cache invalidation work on each restore.
With recompiler block linking enabled, unlinking cached branches flushes the
host instruction cache per patched branch. The Windows Release build with
block linking disabled reduced p95 correction work from 20.47 ms to 9.29 ms
in the same 6,400-frame probe with pooled buffers. The recompiler, renderer,
game inputs, packet schedule and state checks were retained. A prototype
batch flush was slower than disabling linking and was left out of the build.

For this configuration build the SPU-patched core using
`-DCMAKE_BUILD_TYPE=Release`. Use `--no-block-linking` in both the baseline
and rollback commands. The core must advertise that option and the rollback
worker checks all effective options against its fresh baseline. The measured
Release DLL hash was
`9e72d4ded35ed5308916e16448edc1c3c39651969c2f6fde68b4e3293eea6347`.

`--replay-steps 2` also limits a correction to two replayed frames per
virtual tick. Packets keep arriving during recovery. A new correction can
rewind the replay already executed. Inputs that arrive for frames still
ahead of that cursor are used when the replay reaches them. The worker
catches up to the original speculative frontier before advancing new frames.
This can stretch a deep correction over multiple ticks. It leaves the
configured input buffer at two ticks. `rollback_work_ms` reports the work
of each correction slice, and `work_ms` includes any new frame advanced on
the same tick. Both retain the earlier measurement boundary, with diagnostic
hashing and virtual packet simulation measured outside core work.

The two-worker Release baseline matched all 13,706 original signatures
and the final placements. The full trials below used that baseline,
`--delay 2 --window 8 --seed 2401`, and block linking disabled. All peers
confirmed the complete race and kept two ticks of p95 input delay.

| Profile | Replay frames per tick | p95 correction work in ms | Max correction work in ms | Correction overruns | Simulated stalls |
| --- | ---: | --- | --- | --- | --- |
| 80 ms with jitter | 8 | 6.26 / 6.25 | 11.90 / 15.30 | 0 / 0 | 0 / 0 |
| 80 ms with jitter and loss | 8 | 6.17 / 5.84 | 7.57 / 12.96 | 0 / 0 | 0 / 0 |
| 80 ms with jitter | 2 | 5.78 / 5.76 | 7.10 / 12.25 | 0 / 0 | 0 / 0 |
| 80 ms with jitter and loss | 2 | 6.12 / 5.72 | 137.95 / 8.96 | 1 / 0 | 2 / 7 |
| 120 ms with jitter and loss | 8 | 10.79 / 9.85 | 67.43 / 31.28 | 11 / 15 | 5 / 5 |
| 120 ms with jitter and loss | 3 | 8.54 / 8.55 | 12.82 / 69.88 | 0 / 1 | 24 / 42 |
| 120 ms with jitter and loss | 2 | 6.83 / 6.62 | 7.88 / 15.26 | 0 / 0 | 197 / 424 |

In the two-frame 120 ms trial, seat 2's maximum virtual input delay was
10 ticks, up from seven without slicing. The three-frame cap reduced the
stall count, with one measured correction over budget. A few whole ticks
still went over budget in the profiles with zero correction overruns. A separately
instrumented unsliced run also saw a 125 ms save on a tick with no correction.
The measurements qualify the timed correction slices for the listed runs.
They leave Windows scheduling, full-tick deadlines, and the cost of
presenting a corrected frame in the desktop launcher unqualified.

### Continuing frame production through a loss burst

The 120 ms profile withheld new input for the ten-tick burst and the
following delivery delay. With an eight-frame window, both peers reached
frame 5,608 while their last contiguous remote input was frame 5,600.
The wider window (`--window 16`) covers that observed gap. At tick 5,615,
port 2 needed to replay 13 frames. An unsliced control completed without
virtual stalls but took 31.01 ms of core work on that tick, before validation.
The packet loss schedule, history length, and two-tick input buffer stayed
the same.

`--prediction-lane` starts a second software core from a private copy of
the exact same DLL. When a correction needs more frames than the replay
limit, the secondary core starts at the previously presented checkpoint
using Libretro's same-binary context. It advances speculative frames with
the next local inputs and the remote inputs available at each tick. The
primary core replays the corrected inputs concurrently and resumes frame
production after catching up. The secondary core never supplies confirmed
state. This keeps producing new headless frame buffers while the visible
prediction can temporarily differ from the corrected timeline. The trial
reports that lag separately from local input scheduling and stalls.

The prediction-lane trial captures immutable RAM and framebuffer evidence
on the primary core. It drops snapshots superseded by replay and hashes
each confirmed snapshot on an ordered audit worker, using the original
SHA-256 checks. The audit queue is bounded, and the trial drains it before
reporting a match. `tick_ms` is elapsed time for each whole virtual tick,
including packet processing, evidence capture, and any waits for the
prediction or audit workers. The final diagnostic audit drain happens
after the last tick. `work_ms` retains the earlier primary-core metric.

Use the Release baseline with block linking disabled from the previous
section. Both below-normal workers are headless. `--pace` aligns tick
starts to a 60 Hz wall clock and counts late finishes against the
scheduled deadline, including late wakeups. `--require-frame-budget`
returns failure if either peer stalls, exceeds the whole-tick limit, or
misses a paced deadline, even when all frames synchronize.

```powershell
python -B tool/ps1_netplay/rollback.py --core "$core" --disc "$cue" --bios "$bios" `
  --trace tool/ps1_netplay/fixtures/ctr_usa_coco_park_versus.json `
  --baseline "$output/worker-1/run.json" --output "$trial" --profile 120ms-loss `
  --no-block-linking --delay 2 --window 16 --seed 2401 --replay-steps 2 `
  --prediction-lane --benchmark-priority below-normal --pace --require-frame-budget
```

Both unpaced below-normal runs verified all 13,706 authoritative frames
with the original placements, two ticks of local input delay, and zero
virtual stalls. Neither met the strict whole-tick budget.

| Replay cap | Whole-tick p95 in ms | Whole-tick max in ms | Whole-tick overruns |
| --- | --- | --- | --- |
| 2 | 6.36 / 8.22 | 88.83 / 92.25 | 4 / 2 |
| 3 | 6.72 / 10.38 | 103.85 / 109.86 | 5 / 7 |

In the two-frame run, five of the six overruns occurred with the
prediction lane idle and most of their elapsed time was spent inside
primary core calls. The single lane-active overrun was 17.34 ms at tick
5,625. This instrumentation does not identify what blocked the native
calls or establish an actual on-screen frame cadence.

The paced two-frame run also matched all 13,706 frames, maintained the
two-tick local buffer throughout, and had zero virtual stalls. Its whole-tick
p95 was 6.84 / 9.16 ms and its maximum was 65.53 / 96.43 ms. It recorded
7 / 8 work overruns and 27 / 28 scheduled deadline misses. Several peaks
occurred at the same race frames on both peers. During the burst, the
authoritative simulation trailed the speculative frontier by as many as
four frames on port 1 and 12 on port 2. The strict gate failed.

Two unpaced diagnostic controls changed only disc I/O settings and still
matched the same full reference with zero virtual stalls. Preloading the
disc while retaining asynchronous reads left 2 / 1 overruns with maxima
of 113.49 / 111.78 ms. Preloading with synchronous reads left 3 / 3
overruns with maxima of 30.25 / 25.62 ms. Neither configuration passed the
whole-tick budget, and the I/O settings remain at the baseline values.

### Native spike attribution and mitigation

The native probe measured `retro_run`, serialize and restore, with nested
timers for software GPU synchronization, GPU queue space, CD reader waits,
CD worker operations, and recompiler block compilation. One 49.62 ms
step spent 36.96 ms in `GPUBackend::Sync`. Another 20.16 ms step spent
16.49 ms in `CompileBlock`. The latter came from the prediction core
during its first run after a transfer. CD wait time in these calls was
under 0.02 ms. A separate Windows thread-cycle probe also observed long
delays with low calling-thread cycle counts, including with inline GPU.
Those samples show that active CPU work alone does not explain every peak.
The cycle counts do not distinguish off-CPU scheduling from other waits.

`--inline-gpu` disables SwanStation's software-rendering worker and its
per-frame queue fences. `--cpu CachedInterpreter` selects cached guest
instruction execution without native JIT compilation. Both options apply
to the baseline, primary and prediction cores. Recompiler plus inline GPU
still matched all original signatures. Cached interpretation diverged
from the recompiler RAM at frame 574, so it uses its own two-run baseline.
Both cached runs used the original 13,706-frame input tape and reached the
same first and second placements. Port 2 won after three laps and port 1
was placed second with one lap completed, versus two in the recompiler
reference.

With the prediction lane enabled, the replay cap now covers corrected
and new primary-core steps together. For example, a two-frame replay with
one new frame due uses the separate prediction lane with a cap of two.
This avoids packing three primary steps into one tick while the lane can
produce the next speculative frame concurrently. The receipt reports the
actual maximum primary step count. The whole-tick metric still includes
checkpoint transfers, evidence capture, and waits for the prediction or
audit workers.

Generate a fresh Release baseline from the same DLL, disc, BIOS, and input
tape with `--runs 2 --interval 1 --ctr-finish --cpu CachedInterpreter
--inline-gpu --no-block-linking`. Then use the paced 120 ms command above
with `--cpu CachedInterpreter --inline-gpu --benchmark-priority normal`
and the new baseline. Normal priority applies only to the two headless
benchmark processes. Neither timing mode changes the packet history,
random seeds, packet loss, jitter, or the two-tick input buffer.

On the original scheduler, cached interpretation with inline GPU finished
both paced races without virtual stalls. Its whole-tick p95 was 10.35 /
12.92 ms and its maximum was 22.47 / 21.75 ms. The peers still exceeded
16.67 ms on 105 / 216 ticks and missed 120 / 249 scheduled deadlines.
This isolates the lower peaks from the effect of the new shared step cap.

The same paced configuration with the shared cap verified all 13,706
frames on both peers, with two primary steps at most, zero virtual stalls,
and two ticks of local input delay throughout. The peers recorded p95
whole-tick work of 11.00 / 11.94 ms, 6 / 7 work overruns and 18 / 20
scheduled deadline misses. Maximum work was 50.21 / 58.77 ms. The cap
reduced recurring overruns while the strict gate still failed.

An unpaced normal-priority recompiler control with inline GPU and the
shared cap also matched all original signatures and placements, with no
virtual stalls and a two-tick maximum local delay. Its p95 work was
8.17 / 9.75 ms. Each peer had five work overruns, with maxima of
21.66 / 29.37 ms. The control still showed expensive native calls in
the prediction core, consistent with the retained recompiler path.
