"""Check two real Windows runner workers without opening a desktop window."""

import argparse
from contextlib import ExitStack
import json
from pathlib import Path
from queue import Queue
from subprocess import CREATE_NO_WINDOW, IDLE_PRIORITY_CLASS, PIPE, Popen, TimeoutExpired
import sys
from tempfile import TemporaryDirectory
from threading import Thread
from time import monotonic, sleep


class Peer:
    def __init__(self, executable, core, disc, bios, seat):
        self.lines = Queue()
        self.process = Popen(
            [executable, core, disc, bios, str(seat)],
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
    args = parser.parse_args()
    if args.frames < 120:
        parser.error("at least 120 frames are required to compare a fingerprint")
    if args.trace and args.checkpoint_guest:
        parser.error("choose a full race trace or a held-guest checkpoint probe")

    with ExitStack() as cleanup:
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
            traced_race(peers, frames)
            return
        assert peers[0].send("pad 8") == "pad"
        assert peers[1].send("pad 256") == "pad"
        deadline = monotonic() + args.frames / 25 + 15
        histories = [{}, {}]
        active = [False, False]
        while min(state[0] for state in states) < args.frames:
            if monotonic() > deadline:
                raise TimeoutError(f"Both peers did not reach the target, frames={list(s[0] for s in states)}")
            states = [peer.sync(states[1 - seat][1], states[1 - seat][2])
                      for seat, peer in enumerate(peers)]
            for seat, state in enumerate(states):
                histories[seat].update(state[3])
                active[seat] |= any(buttons == (8 if seat == 0 else 256) for _, buttons in state[2])
            sleep(0.002)
        assert all(active), "A local controller never entered the exchanged timeline"
        for frame in range(119, args.frames, 120):
            assert histories[0][frame] == histories[1][frame], f"PS1 RAM diverged at frame {frame}"
        print(f"Both embedded cores confirmed {args.frames} frames, with both seats active "
              f"and {args.frames // 120} matching RAM fingerprints.")
        if args.checkpoint_guest:
            verify_checkpoint(args, peers[0], cleanup)


def verify_checkpoint(args, host, cleanup):
    # Allow the final batch of queued inputs to drain before capturing RAM.
    sleep(0.1)
    held_frame = host.sync()[0]
    expected = host.send("fingerprint")
    directory = cleanup.enter_context(TemporaryDirectory(prefix="anyps5-worker-state-"))
    path = json.dumps((Path(directory) / "state").as_posix())
    assert host.send(f"checkpoint 1 {path}").startswith(f"checkpoint {held_frame} ")
    assert host.sync()[0] == held_frame
    guest = Peer(args.probe.resolve(), args.core.resolve(), args.checkpoint_guest.resolve(), args.bios.resolve(), 1)
    cleanup.callback(guest.close)
    assert guest.receive() == "ready"
    before = guest.send("fingerprint")
    assert before != expected, "The guest already had the expected state before import"
    assert guest.send(f"restore 2 {path}") == "rejected"
    assert guest.send("fingerprint") == before
    assert guest.send(f"restore 1 {path}") == "restored"
    assert guest.send("fingerprint") == expected
    assert guest.sync()[0] == 0, "The guest advanced before the match started"
    assert guest.send("start") == "started"
    assert guest.send(f"restore 1 {path}") == "unavailable"
    print("The held native guest restored the host RAM with a renamed CUE and rejected a wrong disc hash.")


def read_trace(trace):
    # Reuse the original harness' trace validator and game-owned finish gate.
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tool" / "ps1_netplay"))
    from determinism import normalize_trace

    spans = normalize_trace(json.loads(trace.read_text()))
    return [pads for count, *pads in spans for _ in range(count)]


def traced_race(peers, frames):
    assert frames[:3] == [[0, 0]] * 3, "The native delay starts with neutral input"
    states = [peer.sync() for peer in peers]
    histories = [{}, {}]
    pads = [0, 0]
    for frame in range(len(frames)):
        # Frame f+2 is captured when the worker waits for frame f. Exchange
        # only frame f after setting the pad it must capture at frame f+1.
        upcoming = frames[frame + 3] if frame + 3 < len(frames) else [0, 0]
        for seat, mask in enumerate(upcoming):
            if pads[seat] != mask:
                assert peers[seat].send(f"pad {mask}") == "pad"
                pads[seat] = mask
        outputs = [dict(state[2])[frame] for state in states]
        assert outputs == frames[frame], f"Script input mismatch at frame {frame}"
        for seat, peer in enumerate(peers):
            states[seat] = peer.sync(frame - 1, [(frame, outputs[1 - seat])])
        deadline = monotonic() + 3
        for seat, peer in enumerate(peers):
            state = states[seat]
            while state[0] <= frame or frame + 3 not in dict(state[2]):
                if monotonic() > deadline:
                    raise TimeoutError(f"Seat {seat + 1} stopped advancing at frame {frame}")
                sleep(0.001)
                state = peer.sync(frame - 1)
            states[seat] = state
            histories[seat].update(state[3])
        if (frame + 1) % 120 == 0:
            assert histories[0][frame] == histories[1][frame], f"PS1 RAM diverged at frame {frame}"
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
