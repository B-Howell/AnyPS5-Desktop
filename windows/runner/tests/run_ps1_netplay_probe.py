"""Check two real Windows runner workers without opening a desktop window."""

import argparse
from contextlib import ExitStack
import json
from pathlib import Path
from queue import Queue
from shutil import copyfile
from subprocess import CREATE_NO_WINDOW, IDLE_PRIORITY_CLASS, PIPE, Popen, TimeoutExpired
import sys
from tempfile import TemporaryDirectory
from threading import Thread
from time import monotonic, sleep


class Peer:
    def __init__(self, executable, core, disc, bios, seat, *, local=False, saves=None, recompiler=False):
        self.lines = Queue()
        arguments = [executable, core, disc, bios, str(seat)]
        if local:
            arguments.append("local")
        if recompiler:
            arguments.append("recompiler")
        if saves is not None:
            arguments.extend(("ordinary", saves))
        self.process = Popen(
            arguments,
            stdin=PIPE, stdout=PIPE, text=True,
            creationflags=CREATE_NO_WINDOW | IDLE_PRIORITY_CLASS,
        )
        Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line.strip())
        self.lines.put(None)

    def receive(self):
        line = self.lines.get(timeout=35)
        if line is None:
            raise RuntimeError(f"Native probe exited with code {self.process.wait(timeout=5)}")
        return line

    def send(self, command):
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()
        return self.receive()

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.write("quit\n")
            self.process.stdin.flush()
        try:
            self.process.wait(timeout=10)
        except TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise
        if self.process.returncode:
            raise RuntimeError(f"Native probe exited with code {self.process.returncode}")

    def sync(self, acknowledgement=-1, inputs=()):
        values = [acknowledgement, len(inputs)]
        values.extend(value for row in inputs for value in row)
        result = iter(self.send("sync " + " ".join(map(str, values))).split())
        frame, received, count = (int(next(result)) for _ in range(3))
        local = [(int(next(result)), int(next(result))) for _ in range(count)]
        fingerprints = {int(next(result)): next(result) for _ in range(int(next(result)))}
        if next(result, None) is not None:
            raise RuntimeError("Unexpected native probe response")
        return frame, received, local, fingerprints


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for path in ("probe", "core", "disc", "bios"):
        parser.add_argument("--" + path, type=Path, required=True)
    parser.add_argument("--frames", type=int, default=650)
    parser.add_argument("--trace", type=Path, help="Drive the exact two-player CTR fixture and require the race finish")
    parser.add_argument("--checkpoint-guest", type=Path, help="Verify a held peer can import with a renamed CUE")
    parser.add_argument("--cutover", action="store_true", help="Replace the second player and verify the new input epoch")
    parser.add_argument("--cutover-frame", type=int, help="Trace frame where the replacement guest takes over")
    parser.add_argument("--local-handoff", action="store_true", help="Join a host already playing locally")
    parser.add_argument("--ordinary-checkpoint", action="store_true",
                        help="Verify that normal play exports only a blank match card")
    parser.add_argument("--ordinary-control-core", type=Path,
                        help="Also check an older core lacks the ordinary-play export capability")
    parser.add_argument("--ordinary-restore", action="store_true",
                        help="Restore an ordinary hardware checkpoint into two isolated match workers")
    parser.add_argument("--ordinary-park", action="store_true",
                        help="Hold and recover the original worker using its private native checkpoint")
    args = parser.parse_args()
    if args.frames < 120:
        parser.error("at least 120 frames are required to compare a fingerprint")
    if args.cutover and not args.checkpoint_guest:
        parser.error("--cutover requires --checkpoint-guest")
    if args.cutover_frame is not None and not (args.cutover and args.trace):
        parser.error("--cutover-frame requires --cutover and --trace")
    if args.cutover and args.trace and args.cutover_frame is None:
        parser.error("a traced cutover requires --cutover-frame")
    if args.local_handoff and (not args.checkpoint_guest or args.trace or args.cutover):
        parser.error("--local-handoff requires --checkpoint-guest and runs independently of --trace and --cutover")
    if args.ordinary_checkpoint and (args.local_handoff or args.checkpoint_guest or args.trace):
        parser.error("--ordinary-checkpoint runs independently of netplay checks")
    if args.ordinary_control_core and not args.ordinary_checkpoint:
        parser.error("--ordinary-control-core requires --ordinary-checkpoint")
    if args.ordinary_restore and not args.ordinary_checkpoint:
        parser.error("--ordinary-restore requires --ordinary-checkpoint")
    if args.ordinary_park and not args.ordinary_restore:
        parser.error("--ordinary-park requires --ordinary-restore")

    with ExitStack() as cleanup:
        if args.ordinary_checkpoint:
            verify_ordinary_checkpoint(args, cleanup)
            return
        if args.local_handoff:
            verify_local_handoff(args, cleanup)
            return
        frames = read_trace(args.trace) if args.trace else None
        peers = []
        for seat in range(2):
            peer = Peer(args.probe.resolve(), args.core.resolve(), args.disc.resolve(), args.bios.resolve(), seat)
            cleanup.callback(peer.close)
            peers.append(peer)
        assert all(peer.receive() == "ready" for peer in peers)
        states = [peer.sync() for peer in peers]
        assert all(state[:3] == (0, -1, [(0, 0), (1, 0)]) for state in states)
        assert peers[0].send("start") == "started"
        sleep(0.075)
        assert peers[0].sync()[0] == 0, "A missing remote input advanced the emulator"
        assert peers[1].send("start") == "started"
        if args.trace:
            traced_race(peers, frames, args, cleanup)
            return
        assert peers[0].send("pad 8") == "pad"
        assert peers[1].send("pad 256") == "pad"
        histories = [{}, {}]
        active = [False, False]
        def advance(target):
            nonlocal states
            deadline = monotonic() + (target - min(state[0] for state in states)) / 25 + 15
            while min(state[0] for state in states) < target:
                if monotonic() > deadline:
                    raise TimeoutError(f"Both peers did not reach the target, frames={list(s[0] for s in states)}")
                states = [peer.sync(states[1 - seat][1], states[1 - seat][2])
                          for seat, peer in enumerate(peers)]
                for seat, state in enumerate(states):
                    histories[seat].update(state[3])
                    active[seat] |= any(buttons == (8 if seat == 0 else 256) for _, buttons in state[2])
                sleep(0.002)

        advance(args.frames)
        assert all(active), "A local controller never entered the exchanged timeline"
        for frame in range(119, args.frames, 120):
            assert histories[0][frame] == histories[1][frame], f"PS1 RAM diverged at frame {frame}"
        print(f"Both embedded cores confirmed {args.frames} frames, with both seats active "
              f"and {args.frames // 120} matching RAM fingerprints.")
        if args.checkpoint_guest:
            def during_transfer(frame):
                assert peers[0].send("pad 64") == "pad"
                assert peers[1].send("pad 8") == "pad"
                advance(frame + 180)
            verify_checkpoint(args, peers[0], cleanup, during_transfer)


def verify_ordinary_checkpoint(args, cleanup):
    root = Path(cleanup.enter_context(TemporaryDirectory(prefix="anyps5-ordinary-ps1-")))
    saves = root / "saves"
    saves.mkdir()
    bios = root / "scph1001.bin"
    copyfile(args.bios, bios)
    disc = args.disc.resolve()
    card = saves / (disc.stem + ".srm")
    marker = b"AnyPS5 synthetic ordinary save marker"
    snapshot = root / "snapshot"
    path = json.dumps(snapshot.as_posix())

    def boot(core, owner):
        peer = Peer(args.probe.resolve(), core.resolve(), disc, bios, 0, saves=saves)
        owner.callback(peer.close)
        assert peer.receive() == "ready"
        return peer

    with ExitStack() as seed:
        boot(args.core, seed)
    blank = card.read_bytes()
    assert len(blank) == 128 * 1024
    private = blank[:-len(marker)] + marker
    card.write_bytes(private)

    with ExitStack() as active:
        peer = boot(args.core, active)
        renderer = peer.send("renderer")
        assert peer.send("local-support") == "yes"
        assert peer.send("resume-checkpoint") == "unavailable"
        assert peer.send(f"checkpoint 1 {path}") == "unavailable"
        assert peer.send(f"stale-blank 1 {path}") == "unavailable"
        assert peer.send(f"cancel-blank 1 {path}") == "cancelled"
        assert not snapshot.exists()
        before = int(peer.send("published"))
        deadline = monotonic() + 3
        while True:
            reply = peer.send(f"blank-checkpoint 1 {path}")
            if reply not in ("rejected", "unavailable") or monotonic() >= deadline:
                break
            sleep(0.017)
        name, frame, size = reply.split()
        data = snapshot.read_bytes()
        assert name == "checkpoint" and int(frame) > 0 and int(size) == len(data)
        assert marker not in data and blank in data
        assert card.read_bytes() == private
        deadline = monotonic() + 3
        while int(peer.send("published")) <= before + 1:
            if monotonic() >= deadline:
                raise TimeoutError("Ordinary play stopped publishing after the checkpoint")
            sleep(0.017)
        deadline = monotonic() + 3
        while True:
            assert peer.send("pause") == "pause"
            sleep(0.05)
            paused = peer.send("published")
            # A busy boundary still completes the request without moving
            # the paused source. A match can retry on a later boundary.
            operation = "park-checkpoint" if args.ordinary_park else "blank-checkpoint"
            paused_reply = peer.send(f"{operation} 1 {path}")
            assert paused_reply.startswith("checkpoint ") or paused_reply == "rejected"
            assert peer.send("published") == paused
            if paused_reply != "rejected" or not args.ordinary_restore or monotonic() >= deadline:
                break
            assert peer.send("resume") == "resume"
            wait_for_picture(peer, int(paused) + 1)
        if args.ordinary_restore:
            assert renderer == "hardware", "The source did not use hardware rendering"
            assert peer.send("cpu") == "Recompiler"
            assert paused_reply.startswith("checkpoint "), "The held frame could not be exported"
            held_snapshot = snapshot.read_bytes()
            assert len(held_snapshot) == int(paused_reply.split()[2])
            assert marker not in held_snapshot and blank in held_snapshot
            if args.ordinary_park:
                assert peer.send("resume") == "resume"
                sleep(0.08)
                assert peer.send("published") == paused, "Normal playback released the match hold"
                assert peer.send(f"park-checkpoint 1 {path}") == "unavailable"
                assert peer.send(f"erase-card-tail {len(marker)}") == "erased"
            verify_ordinary_restore(args, peer, bios, path)
            assert peer.send("published") == paused, "The original session moved during the match probe"
            if args.ordinary_park:
                assert peer.send("pause") == "pause"
                assert peer.send("resume-checkpoint") == "resumed"
                assert peer.send("resume-checkpoint") == "unavailable"
                assert peer.send(f"cancel-park 1 {path}") == "cancelled"
                assert peer.send("resume-checkpoint") == "unavailable"
                print("Native recovery restored the held source after a scratch card mutation.")
        assert peer.send("resume") == "resume"
        wait_for_picture(peer, int(paused) + 1)
    assert card.read_bytes() == private

    if args.ordinary_control_core:
        with ExitStack() as active:
            peer = boot(args.ordinary_control_core, active)
            assert peer.send("local-support") == "no"
            assert peer.send(f"blank-checkpoint 1 {path}") == "unavailable"
    assert card.read_bytes() == private
    print(f"Ordinary {renderer} worker exported {size} bytes at frame {frame}, kept the source card, "
          "and continued publishing after cancellation and export.")


def verify_ordinary_restore(args, source, bios, path):
    expected = source.send("fingerprint")
    with ExitStack() as match:
        peers = []
        for seat in range(2):
            peer = Peer(args.probe.resolve(), args.core.resolve(), args.disc.resolve(), bios, seat,
                        recompiler=True)
            match.callback(peer.close)
            assert peer.receive() == "ready"
            assert peer.send("cpu") == "Recompiler"
            assert peer.send("fingerprint") != expected
            assert peer.send(f"restore 1 {path} 0") == "restored"
            assert peer.send("fingerprint") == expected
            assert peer.send("start") == "started"
            peers.append(peer)
        verify_new_input_epoch(*peers, input_masks=(64, 256))
        assert all(peer.send("renderer") == "software" and int(peer.send("published")) > 0
                   for peer in peers)
    assert source.send("fingerprint") == expected
    print("Both match workers restored the original hardware session's RAM and ran a new input epoch.")


def verify_checkpoint(args, host, cleanup, during_transfer):
    checkpoint = capture_checkpoint(host, cleanup)
    during_transfer(checkpoint[0])
    guest = replay_checkpoint(args, host, cleanup, checkpoint)
    if args.cutover:
        verify_new_input_epoch(host, guest)


def capture_checkpoint(host, cleanup):
    # Allow the final batch of queued inputs to drain before capturing RAM.
    sleep(0.1)
    held_frame = host.sync()[0]
    checkpoint = capture_held_checkpoint(host, cleanup, held_frame)
    assert host.sync()[0] == held_frame
    return checkpoint


def capture_held_checkpoint(host, cleanup, held_frame):
    expected = host.send("fingerprint")
    directory = cleanup.enter_context(TemporaryDirectory(prefix="anyps5-worker-state-"))
    path = json.dumps((Path(directory) / "state").as_posix())
    assert host.send(f"checkpoint 1 {path}").startswith(f"checkpoint {held_frame} ")
    return held_frame, expected, path


def replay_checkpoint(args, host, cleanup, checkpoint, *, local=False):
    held_frame, expected, path = checkpoint
    guest = Peer(args.probe.resolve(), args.core.resolve(), args.checkpoint_guest.resolve(), args.bios.resolve(), 1)
    cleanup.callback(guest.close)
    assert guest.receive() == "ready"
    before = guest.send("fingerprint")
    assert before != expected, "The guest already had the expected state before import"
    assert guest.send(f"restore 2 {path} {held_frame}") == "rejected"
    assert guest.send("fingerprint") == before
    assert guest.send(f"restore 1 {path} {held_frame}") == "restored"
    assert guest.send("fingerprint") == expected
    assert guest.send(f"replay {held_frame + 1} 1 0 0") == "unavailable"
    published = guest.send("published")
    cursor = held_frame
    if local:
        end = hold_host(host)
    elif args.cutover:
        end = hold_host(host)
        host.sync(inputs=[(end, 65535)])
        sleep(0.08)
        assert host.sync()[0] == end, "A queued remote input advanced the held host"
    else:
        end = host.sync()[0]
    assert end - held_frame >= 180
    host_input_seen = False
    while cursor < end:
        count, *pads = host.send(f"history {cursor}").split()
        assert 0 < int(count) <= 120 and len(pads) == int(count) * 2
        if local:
            assert all(mask == "0" for mask in pads[1::2]), "Local play fed input to the guest port"
            host_input_seen |= "8" in pads[::2]
        assert guest.send(f"replay {cursor} {count} {' '.join(pads)}") == "replayed"
        cursor += int(count)
    if local:
        assert host_input_seen, "The local controller did not enter the recorded history"
    assert cursor == end
    assert guest.send("fingerprint") == host.send("fingerprint")
    assert guest.send("published") == published, "Catch-up published a guest video frame"
    assert guest.send(f"checkpoint 1 {path}") == "unavailable"
    assert guest.sync()[0] == 0, "The guest advanced before the match started"
    assert guest.send("start") == "started"
    assert guest.send(f"restore 1 {path} {held_frame}") == "unavailable"
    assert guest.send(f"replay {cursor} 1 0 0") == "unavailable"
    assert guest.send(f"checkpoint 1 {path}") == "unavailable"
    print(f"The held guest replayed {end - held_frame} host frames and matched the host RAM.")
    if args.cutover or local:
        assert host.send("start") == "started"
    return guest


def hold_host(host):
    status, frame = host.send("hold").split()
    assert status == "held"
    return int(frame)


def wait_for_picture(host, target):
    deadline = monotonic() + 15
    while int(host.send("published")) < target:
        if monotonic() > deadline:
            raise TimeoutError("The local host stopped publishing frames")
        sleep(0.01)


def verify_local_handoff(args, cleanup):
    host = Peer(args.probe.resolve(), args.core.resolve(), args.disc.resolve(), args.bios.resolve(), 0, local=True)
    cleanup.callback(host.close)
    assert host.receive() == "ready"
    assert host.send("start") == "error", "A playing host joined before reaching the cutover barrier"
    wait_for_picture(host, 240)
    first = hold_host(host)
    picture = int(host.send("published"))
    sleep(0.1)
    assert int(host.send("published")) == picture
    checkpoint = capture_held_checkpoint(host, cleanup, first)
    assert host.send("resume-local") == "resumed"
    assert host.send("pad 8") == "pad"
    wait_for_picture(host, picture + 240)
    guest = replay_checkpoint(args, host, cleanup, checkpoint, local=True)
    assert host.send("resume-local") == "unavailable"
    verify_new_input_epoch(host, guest)
    hold_host(host)
    picture = int(host.send("published"))
    assert host.send("resume-local") == "resumed"
    wait_for_picture(host, picture + 30)


def verify_new_input_epoch(host, guest, *, input_masks=None):
    peers = [host, guest]
    states = [peer.sync() for peer in peers]
    assert all(frame == 0 and received == -1 and not hashes
               and all(buttons == 0 for _, buttons in local[:2])
               for frame, received, local, hashes in states), "Stale input or fingerprints survived cutover"
    if input_masks:
        for peer, mask in zip(peers, input_masks):
            assert peer.send(f"pad {mask}") == "pad"
    seen = [False, False]
    fingerprints = [{}, {}]
    deadline = monotonic() + 15
    while min(state[0] for state in states) < 120:
        if monotonic() > deadline:
            raise TimeoutError("The new host and guest input epoch did not reach frame 120")
        states = [peer.sync(states[1 - seat][1], states[1 - seat][2])
                  for seat, peer in enumerate(peers)]
        for seat, state in enumerate(states):
            fingerprints[seat].update(state[3])
            if input_masks:
                seen[seat] |= any(buttons == input_masks[seat] for _, buttons in state[2])
        sleep(0.002)
    assert fingerprints[0][119] == fingerprints[1][119], "PS1 RAM diverged after cutover"
    assert not input_masks or all(seen), "Each seat must supply its own controller input"
    print("The held host and replacement guest matched the first RAM fingerprint in the new input epoch.")


def read_trace(trace):
    # Reuse the original harness' trace validator and game-owned finish gate.
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tool" / "ps1_netplay"))
    from determinism import normalize_trace

    spans = normalize_trace(json.loads(trace.read_text()))
    return [pads for count, *pads in spans for _ in range(count)]


def traced_race(peers, frames, args, cleanup):
    assert frames[:3] == [[0, 0]] * 3, "The native delay starts with neutral input"
    cutover = args.cutover_frame
    if cutover is not None:
        assert 180 < cutover <= len(frames) - 120 and frames[cutover:cutover + 3] == [[0, 0]] * 3, (
            "The cutover must have 180 preceding frames and three neutral frames for the new input buffer")
    states = [peer.sync() for peer in peers]
    histories = [{}, {}]
    pads = [0, 0]
    joining = cleanup.enter_context(ExitStack()) if args.checkpoint_guest else None
    checkpoint = None
    epoch_start = 0
    checkpoint_frame = cutover - 180 if cutover is not None else 6600
    replay_frame = cutover if cutover is not None else 6780
    for frame in range(len(frames)):
        epoch_frame = frame - epoch_start
        # Frame f+2 is captured when the worker waits for frame f. Exchange
        # only frame f after setting the pad it must capture at frame f+1.
        upcoming = frames[frame + 3] if frame + 3 < len(frames) else [0, 0]
        for seat, mask in enumerate(upcoming):
            if pads[seat] != mask:
                assert peers[seat].send(f"pad {mask}") == "pad"
                pads[seat] = mask
        outputs = [dict(state[2])[epoch_frame] for state in states]
        assert outputs == frames[frame], f"Script input mismatch at frame {frame}"
        for seat, peer in enumerate(peers):
            states[seat] = peer.sync(epoch_frame - 1, [(epoch_frame, outputs[1 - seat])])
        deadline = monotonic() + 3
        for seat, peer in enumerate(peers):
            state = states[seat]
            while state[0] <= epoch_frame or epoch_frame + 3 not in dict(state[2]):
                if monotonic() > deadline:
                    raise TimeoutError(f"Seat {seat + 1} stopped advancing at frame {frame}")
                sleep(0.001)
                state = peer.sync(epoch_frame - 1)
            states[seat] = state
            histories[seat].update((epoch_start + cursor, digest) for cursor, digest in state[3].items())
        if (epoch_frame + 1) % 120 == 0:
            assert histories[0][frame] == histories[1][frame], f"PS1 RAM diverged at frame {frame}"
        if joining and frame + 1 == checkpoint_frame:
            checkpoint = capture_checkpoint(peers[0], joining)
        if joining and frame + 1 == replay_frame:
            assert checkpoint is not None
            if cutover is not None:
                peers[1].close()
                peers[1] = replay_checkpoint(args, peers[0], joining, checkpoint)
                epoch_start = cutover
                states = [peer.sync() for peer in peers]
                assert all(state[:2] == (0, -1) for state in states)
            else:
                replay_checkpoint(args, peers[0], joining, checkpoint)
                joining.close()
        if (frame + 1) % 1800 == 0:
            print(f"Verified {frame + 1}/{len(frames)} native frames", flush=True)
    placements = race_placements(peers)
    print(f"Both native peers finished after {len(frames)} frames with {len(histories[0])} matching "
          f"RAM fingerprints: {placements}")


def race_placements(peers):
    from determinism import ctr_finish

    placements = [ctr_finish(lambda address, size: bytes.fromhex(peer.send(f"read {address} {size}")))
                  for peer in peers]
    assert placements[0] == placements[1]
    return placements[0]


if __name__ == "__main__":
    main()
