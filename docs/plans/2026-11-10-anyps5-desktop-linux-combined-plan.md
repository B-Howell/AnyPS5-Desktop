# AnyPS5 Desktop Linux combined integration plan

**Goal:** Correct the combined laptop installation so real emulator setup and
embedded play are available on Linux, then verify CTR through the installed
launcher. A visible application window alone is insufficient acceptance.

**Architecture:** Reuse the published Linux host and shared native session
from `990511f1190e31388162be20e2e1010aac84e32b`, retaining the newer combined
Dart features at `681f8a7`. Reconcile managed Linux shared-library installation
and validation separately from Windows-only online identity policies.

## Native host task

Port the Linux runner, platform audio/video and shared `native/retro` session
from the existing Linux preview. Preserve current unrelated Linux runner
behavior. Run its native fake-core regression tests on the laptop. Reconcile
the current launch/input/disc/settings method contract. No Windows host edits
or user-profile changes belong to this task.

## Managed installer task

Add a failing Linux emulator setup/installer regression before modifying Dart.
Make managed setup, package selection, binary validation and library filenames
host-aware. Preserve Windows package validation and online pins. Linux needs
ELF x86-64 shared objects, not Windows DLLs renamed to shared libraries. Keep
unsupported online modes guarded by their actual native capabilities. Preserve
the existing granular UI and all combined features.

## Integration and acceptance

Run analysis, translation checks, relevant Dart and native regressions, and a
Linux release build at low priority with at most three native jobs. Install a
new versioned complete bundle, retaining the previous bundle and profile.
Close the existing launcher through its normal path only when deployment is
ready. Verify the installed executable, the emulator settings entry, PS1 setup
and a real CTR frame with the transferred game and BIOS. Review changes
independently before calling the replacement usable. Record separately any
online mode whose native backend remains missing or unqualified; never turn
off platform/identity checks to imply support.
