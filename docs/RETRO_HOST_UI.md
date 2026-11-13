# The emulator host in the launcher's UI

[The emulator host client](RETRO_HOST_CLIENT.md) talks to the emulator host
(the separate program that runs PS1 games). This page covers the first piece of
UI built on it: a game's picture in the launcher, and the object that runs one
game in one host. It is not yet part of the launcher's game flow. A PS1 game
still starts the way it did before this change.

## Files

| File | What it does |
| --- | --- |
| [`lib/core/retro_host/retro_host_session.dart`](../lib/core/retro_host/retro_host_session.dart) | `RetroFrameSource` and `RetroHostSession`: the parts of `RetroHostClient` the UI uses. `RetroHostClient` implements them, and tests give a fake. Also `RetroHostStartRequest`, the `start` call's argument. |
| [`lib/ui/retro_host/retro_frame_image.dart`](../lib/ui/retro_host/retro_frame_image.dart) | Turns the host's frames into a `ui.Image`. |
| [`lib/ui/retro_host/retro_frame_view.dart`](../lib/ui/retro_host/retro_frame_view.dart) | Draws a picture on black at an aspect ratio. |
| [`lib/ui/retro_host/retro_host_focus.dart`](../lib/ui/retro_host/retro_host_focus.dart) | Reports whether the launcher's window has input focus. |
| [`lib/ui/retro_host/retro_host_game.dart`](../lib/ui/retro_host/retro_host_game.dart) | `RetroHostGame`: one game in one host. |
| [`lib/ui/retro_host/retro_host_game_view.dart`](../lib/ui/retro_host/retro_host_game_view.dart) | Puts the last three together: a game's picture that pauses the game when focus is lost. |

Each piece does one job and can be used alone. A settings preview can use
`RetroFrameView` with any picture, and a menu can follow `RetroHostGame` without
showing the picture.

## From frame to picture

The host writes each frame into shared memory and sends `frame`. The client
pins the newest frame and adds an event to `frames`
(`RetroHostClient.frames`). `RetroFrameImage` listens to that stream:

1. **It copies the frame right away.** On each event marked `drawn`, it copies
   the frame's `height` rows of `width` × 4 bytes into a Dart list. The
   client's documentation says why it cannot wait: a frame "stays readable until
   another frame replaces it", and a frame that was not drawn "can be read only
   until the next message". So the copy is made while the event is handled,
   before any other message can arrive. After that, nothing the host writes can
   change the picture.
2. **It makes an image from the copy.** `decodeImageFromPixels` uploads it,
   with `PixelFormat.rgba8888` or `PixelFormat.bgra8888` to match the frame's
   format. Both formats come out as the same colours.
3. **It keeps up by skipping.** Uploading takes time. Frames that arrive during
   an upload are not queued: only the newest one is kept, and it is uploaded
   next. The protocol's `frame` section says this is correct: "Frames can be
   skipped; only the newest frame matters."
4. **It owns the image.** When a new image is ready, the old one is disposed
   and listeners are told. `RawImage` keeps its own clone, so a picture being
   painted is never disposed under it.

Only events marked `drawn` are shown. The client marks a frame drawn only when
its `epoch` belongs to the current game, so a frame left over from a game that
was stopped is never shown. When a game starts or ends, `clear()` removes the
picture and drops any upload still running. `RetroHostGame` also sets
`accepting` to false from the moment its game ends, is stopped or the host is
being shut down, until the next game is accepted. A frame that still arrives in
that time (the client keeps marking frames drawn until `release`) is ignored,
so the old game's last picture never comes back.

When the ring has no frame, the client adds an event with no frame. The picture
then stays as it is, which is what the protocol asks: "the launcher keeps
showing what it showed before".

## The picture on screen

`RetroFrameView` draws a black box. Inside it, centred, is an `AspectRatio`
with the core's display aspect ratio, which holds a `RawImage` stretched to
fill it. So the PS1's non-square pixels look right, and any spare space is
black bars. Pixels are not smoothed by default (`FilterQuality.none`). Before
the first frame only the black box is drawn.

`RetroHostGameView` takes the aspect ratio from `RetroHostGame.aspect`, which
comes from the game's last `status` ("aspect": "The display aspect ratio the
core reports; 1.3333333333333333 until it reports one").

## One game in one host: `RetroHostGame`

`RetroHostGame` owns one `RetroHostSession` and the `RetroFrameImage` of its
frames. `RetroHostGame.launch(command: …)` starts a real host;
`RetroHostGame(session)` takes any session, which is how the tests give a fake.

| Phase | Meaning |
| --- | --- |
| `idle` | No game started yet. |
| `starting` | Waiting for the host's `welcome` and the reply to `start`. |
| `loading` | `start` was accepted; `status.ready` is still false. |
| `playing` | `status.ready` is true. |
| `ended` | The game ended. `endStatus` holds the status it ended with (`errorCode` says why), and `failure` holds the reason when `start` was refused or no status came. |
| `closed` | The host was shut down. |

- **Start.** `start(RetroHostStartRequest)` waits for `ready`, sends `start`
  with the protocol's fields (`core`, `disc`, `system`, `saves`, and `options`
  and `initialDisc` only when given), clears the picture, and then asks
  `status` every 500 ms while a game is loaded. Only one game is started per
  `RetroHostGame`.
- **Status.** Each `status` updates the aspect ratio. A ready status moves the
  game from `loading` to `playing`. An ended status ends it. After a host
  failure, the client's own short failure report (`errorCode` `hostExited` or
  `hostHung`) ends it the same way. When the host's connection ends, the game
  asks `status` at once instead of waiting for the next poll.
- **Input.** `input(port, buttons, …)` forwards a controller state to the host,
  but only while a game is loaded and the window has input focus. The client
  zeroes both ports when focus is lost, so dropping input while the window has
  no focus keeps them at zero.
- **Pausing.** The game is paused while the player paused it or while the
  window has no focus, and these two are tracked apart. Losing focus pauses
  the game (`pause` with `true`). Getting focus back resumes it, unless the
  player had paused it. A game started while the window has no focus is
  paused as soon as `start` is accepted. `pause` is sent only when the
  combined state changes.
- **Focus.** `setFocused` also sets `RetroHostClient.inputFocus`, which zeroes
  the controllers and their motors, as the protocol's `input` and `rumble`
  sections require. `RetroHostFocus` takes focus from the app's lifecycle:
  the window has focus while it is `resumed`, and loses it when it is
  inactive, hidden or paused. After its first frame, and whenever it is given
  another game, it also passes on the state the app is already in. So a view
  opened while the window has no focus still pauses its game.
  Once the host has ended or been shut down, focus is still recorded but no
  longer passed to the client, whose streams are closed by then.
- **Stop.** `stop()` calls `stopGame()` (which enforces the 10-second stop
  limit), then `release`, and returns the status the game ended with. Stopping
  a game that is still `starting` cancels it. If `start` was not sent yet, it
  never is. If it was sent, the game is stopped and released as soon as the
  host's reply comes, and `stop()` waits for that.
- **Shut down.** `shutdown()` sends `shutdown`, waits for the connection to
  end (the client kills a host that has not exited within 15 seconds), then
  calls `close()`. `dispose()` shuts down too. Calling `shutdown()` again
  returns the same shutdown.

Nothing here waits on the host on the UI thread. Every wait is a `Future`,
and the client's time limits make sure each one ends.

## Tests

The tests in `test/ui/retro_host` use a fake session and fake frames, kept in
native memory as a real ring slot would be, so no host is started.

- [`retro_frame_image_test.dart`](../test/ui/retro_host/retro_frame_image_test.dart):
  - `rgba8` and `bgra8` frames read back as the right colours;
  - frames not marked drawn are skipped;
  - the copy is taken when the event arrives, so later writes to the slot do
    not show;
  - while an upload runs, only the newest frame is uploaded next;
  - `clear()` drops a frame still being uploaded.
- [`retro_host_game_test.dart`](../test/ui/retro_host/retro_host_game_test.dart)
  covers:
  - the `start` argument;
  - the status example from the protocol's `status` section;
  - input filtering, pausing on focus loss and the player's own pause;
  - an ended status, a refused `start`, a host that never says `welcome`, and
    a host failure while playing;
  - stopping while waiting for `welcome`, and while `start` waits for its reply;
  - frames that arrive after the game ended or during shutdown;
  - focus changes after shutdown or a host failure;
  - `stop`, `shutdown` and `dispose`, including disposing before a game was
    started on a host that is gone.
- [`retro_host_game_view_test.dart`](../test/ui/retro_host/retro_host_game_view_test.dart)
  checks the letterboxing and that a frame from the fake host reaches the
  screen. It also checks that an `inactive` lifecycle pauses the game and
  `resumed` resumes it, and that a view opened while the window is inactive
  tells its game at once.

A widget test runs in fake time, but images are made by the engine in real
time. So the view test waits for a picture by taking turns: a short real wait
(`tester.runAsync`), then `tester.pump()`.

```bash
flutter test test/ui/retro_host
```

## Not yet

- **Not in the game flow.** Starting a PS1 game still uses the old path.
  Still to do: switching it to `RetroHostGame`, picking the host's files, and
  the settings for using the host.
- **No controllers or keyboard.** Nothing yet turns gamepad or keyboard state
  into `input` calls, connects port 2 (`connectedPorts`), or forwards `rumble`
  to a controller.
- **No in-game menu.** Disc changes (`changeDisc`), core options (`option`),
  volume, and the loading and error screens (`progressLabel`, `errorCode` in
  the player's language) are not shown yet.
- **One copy per frame.** Each frame is copied once and uploaded through
  `decodeImageFromPixels`. A texture that shares the ring with the GPU would
  avoid the copy. That is worth doing only if a trace shows the copy costs
  frames.
