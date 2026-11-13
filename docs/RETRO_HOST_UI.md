# The emulator host in the launcher's UI

[The emulator host client](RETRO_HOST_CLIENT.md) talks to the emulator host
(the separate program that runs PS1 games). This page covers the UI built on
it: a game's picture in the launcher, the object that runs one game in one
host, the controllers that play it, and the model of its in-game menu. It is
not yet part of the launcher's game flow. A PS1 game still starts the way it
did before this change.

## Files

| File | What it does |
| --- | --- |
| [`lib/core/retro_host/retro_host_session.dart`](../lib/core/retro_host/retro_host_session.dart) | `RetroFrameSource` and `RetroHostSession`: the parts of `RetroHostClient` the UI uses. `RetroHostClient` implements them, and tests give a fake. Also `RetroHostStartRequest`, the `start` call's argument. |
| [`lib/ui/retro_host/retro_frame_image.dart`](../lib/ui/retro_host/retro_frame_image.dart) | Turns the host's frames into a `ui.Image`. |
| [`lib/ui/retro_host/retro_frame_view.dart`](../lib/ui/retro_host/retro_frame_view.dart) | Draws a picture on black at an aspect ratio. |
| [`lib/ui/retro_host/retro_host_focus.dart`](../lib/ui/retro_host/retro_host_focus.dart) | Reports whether the launcher's window has input focus. |
| [`lib/ui/retro_host/retro_host_game.dart`](../lib/ui/retro_host/retro_host_game.dart) | `RetroHostGame`: one game in one host. |
| [`lib/ui/retro_host/retro_host_game_view.dart`](../lib/ui/retro_host/retro_host_game_view.dart) | Puts the last three together: a game's picture that pauses the game when focus is lost. |
| [`lib/core/retro_host/retro_pad.dart`](../lib/core/retro_host/retro_pad.dart) | `RetroPadInput`: one controller's state as the protocol's `input` carries it, made from the launcher's `PadState`. |
| [`lib/core/retro_host/retro_seats.dart`](../lib/core/retro_host/retro_seats.dart) | `RetroSeats`: which controller sits at each of the PS1's two ports. |
| [`lib/ui/retro_host/retro_host_controls.dart`](../lib/ui/retro_host/retro_host_controls.dart) | `RetroHostControls`: plays a `RetroHostGame` with the launcher's controllers, connects port 2 and forwards vibration. `RetroPadReader` is how it reads the controllers. |
| [`lib/ui/retro_host/retro_game_menu.dart`](../lib/ui/retro_host/retro_game_menu.dart) | `RetroGameMenu`: the in-game menu's rows (discs, core options, volume) and what choosing them does. |

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
  but only while a game is loaded and the window has input focus
  (`acceptsInput`). The client zeroes both ports when focus is lost, so
  dropping input while the window has no focus keeps them at zero.
- **Game calls.** `connectedPorts`, `changeDisc` and `setOption` send the
  protocol's methods of the same names, and only while a game is loaded. Each
  gives the host's `true` or `false`. It gives `false` when the call fails,
  and a host failure is then seen by the next status. After a disc change or
  an option the host took, `status` is asked at once, so the menu shows it.
- **Volume.** `setVolume` sends `volume` once the host has greeted the
  launcher, with or without a game. `volume` and `muted` keep what the player
  chose. `RetroHostGame.launch` starts the host with them, and the client
  sends them after `welcome`, as the protocol asks.
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

## Controllers: `RetroHostControls`

`RetroHostControls` turns the launcher's controllers into the protocol's
`input` messages for one `RetroHostGame`. It reads them through a
`RetroPadReader`: the ids of the controllers connected now, in the launcher's
order with Player 1 first, and each one's `PadState`.
`RetroPadReader.inventory` reads a reader's `PadInventory` (SDL, or XInput
and winmm, or evdev).

**Buttons and sticks.** `RetroPadInput.fromPad` follows the bit table of the
protocol's `input` section: Cross 0, Square 1, Select 2, Start 3, D-pad up,
down, left and right 4 to 7, Circle 8, Triangle 9, L1 10, R1 11, L2 12, R2
13, L3 14, R3 15. Buttons go by their place on the pad, as the launcher's
readers name them (`south` is Cross, `east` Circle, `west` Square, `north`
Triangle), so an Xbox pad's A is Cross. PS/Guide, the touchpad and the extra
button send nothing: PS stays the launcher's (home, close the game). A trigger
counts as L2 or R2 from the point where the SDL reader counts it pressed
(0.35). The protocol says "-32768 is fully left or fully up". The launcher's
sticks go from -1 to 1 with down positive, so -1 becomes -32768 and 1
becomes 32767. Settings › Controllers › Stick Dead Zone (`deadzonePercent`)
applies to each stick. The older readers (XInput and winmm, evdev) give no
right stick or analogue triggers, so with them the right stick stays centred.

**Ports.** `RetroSeats` gives each controller a port and keeps it there while
the controller stays connected, so a press on another pad never swaps the
players. When the game starts, Player 1 (the controller used last) is at port
1 and the next controller at port 2. A controller that leaves frees its port.
The other player stays where they are, and the next controller to connect
takes the free port. Port 2 counts as connected while a controller sits
there. The protocol's `connectedPorts` section says "A game starts with 1",
so `connectedPorts` with `2` is sent when the game loads with two
controllers or a second one sits down, and `1` when it leaves. Port 1 always
has a controller in the host.

**Sending.** The controllers are read every 16 ms, as the SDL reader polls
them. A port's state is sent when it changes. The protocol says the launcher
sends it "when the state changes, and once with all zeros when a game starts
or input focus is lost", and the client sends those zeros itself. So whenever
the game stops taking input (not loaded, or no focus), the controls forget
what they sent, and send both ports again in full once it takes input again.
They follow the game's changes as they happen, not only at each read, so
focus lost and back within 16 ms is not missed. A controller held through a
focus change therefore reaches the game again when focus comes back. A port
whose controller left is sent as idle. While `suspended` is true (the in-game
menu is open), both ports are sent as idle. When it becomes false, the
buttons held at that moment stay out of the game until they are let go, as
the launcher's own `PadGate` does when the launcher comes back in front. The
sticks come back at once.

**Vibration.** The protocol's `rumble` section says the launcher "forwards
them to the controller seated at that port, if it can vibrate". So each
`RetroHostGame.rumble` event goes to the controller at that port when the
reader's `PadRumble.canRumble` says it can, as `strong / 65535` and
`weak / 65535`. A `rumble` holds until the next one, but the SDL and evdev
readers stop the motors after the length they are given. So a level that is
not zero is given for `rumbleHold` (2 s) and given again every second. The
client already gives zeros for both ports when the game starts, pauses, ends
or loses focus, and gives nothing while paused or without focus. The controls
add the protocol's last case, "when a controller leaves its port": its motors
stop. Setting `vibration` to false stops the motors and keeps later rumble
away. `dispose` stops any motor the game left running.

## The in-game menu: `RetroGameMenu`

`RetroGameMenu` is the menu's model. It shows no widget: a menu view lists
`rows` and calls the actions. The rows come from the game's last `status`:

- **Discs.** For a game with more than one disc, one `RetroDiscRow` per entry
  of `status.discs.labels`, with the inserted disc marked. A row can be
  chosen when it is not the inserted disc and no change is in progress
  (`discs.busy`). `chooseDisc` sends `changeDisc` with the row's index, which
  the protocol defines as "the index into `discs.labels`". `discChangeFailed`
  is `discs.failed`.
- **Core options.** One `RetroOptionRow` per entry of `status.options`, in the
  host's order. `choice` is the label of `selected`. `pending` is true while
  the chosen value is not yet the `activeValue`, and `restartNeeded` is the
  option's `restart`. `stepOption(key, steps)` moves through `values` and
  stops at the first and last. It sends `option` with `key` and `value`.
- **Volume.** A `RetroVolumeRow` with the game's `volume` and `muted`.
  `stepVolume` moves it by tenths from 0 to 1, and turning it up unmutes.
  `toggleMute` switches `muted`.

`open()` pauses the game (`pause` with `true`, the same as the player's own
pause) and sets the controls' `suspended`, so presses in the menu never reach
the game. `close()` gives the controllers back at once, so a button still
held from the menu reaches the game only once it is pressed again, then
resumes the game. Neither does anything after waiting for the host, so
opening the menu again while a close still waits for its reply keeps the
controllers out. A game that is not loaded has no menu to open.

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

  It also checks that a controller held while the window loses focus reaches
  the game again when focus comes back.
- [`retro_host_controls_test.dart`](../test/ui/retro_host/retro_host_controls_test.dart)
  covers:
  - a port's state sent once, then on each change;
  - port 2 connected when a second controller sits down, or when the game
    loads with two, and let go when it leaves;
  - both ports sent again after focus comes back, also when focus is lost
    and back between two reads;
  - `suspended`, and a button held when it ends kept out until pressed again;
  - vibration sent to the controller at its port, a leaving controller's
    motors stopped, vibration turned off, and `dispose`.
- [`retro_game_menu_test.dart`](../test/ui/retro_host/retro_game_menu_test.dart)
  builds the rows from the protocol's status example. It checks disc changes,
  option steps, volume steps and mute, volume set before `welcome`, and that
  opening the menu pauses the game and suspends the controls, also when it is
  opened again while closing still waits for the host.
- [`retro_pad_test.dart`](../test/core/retro_host/retro_pad_test.dart) checks
  every button against the protocol's bit table, the triggers, both ends of
  the stick range and the dead zone.
  [`retro_seats_test.dart`](../test/core/retro_host/retro_seats_test.dart)
  covers who sits where as controllers come and go.
- [`fake_retro_host_session.dart`](../test/ui/retro_host/fake_retro_host_session.dart)
  holds the fakes: the session, frames, controllers (`FakePads`) and motors
  (`FakeMotors`).

A widget test runs in fake time, but images are made by the engine in real
time. So the view test waits for a picture by taking turns: a short real wait
(`tester.runAsync`), then `tester.pump()`.

```bash
flutter test test/ui/retro_host test/core/retro_host/retro_pad_test.dart test/core/retro_host/retro_seats_test.dart
```

### Against the real host

[`retro_host_game_real_test.dart`](../test/ui/retro_host/retro_host_game_real_test.dart)
runs `RetroHostGame`, `RetroHostControls` and `RetroGameMenu` against the real
host. It reads the same `ANYPS5_RETRO_HOST_REAL` file as the client's real
test ([RETRO_HOST_CLIENT.md](RETRO_HOST_CLIENT.md)), with one more optional
key, `fakeCore`: the host repository's test core (`tests/fake_core.c`, built
beside the host as `fake_core.dll` or `libfake_core.so`). Without the variable
the test is skipped, so CI skips it. Without `fakeCore` only the second case
is skipped.

- **SwanStation.** OpenBIOS boots the PS-EXE. The game reaches `playing`, and
  its `picture` shows two pictures that are not black and differ. A second
  controller sits down at port 2 and then leaves. The test records the calls
  that go through the session: the controls sent `connectedPorts` with `2`,
  then `1`, and the host answered `true` to both. `stop` then ends the game
  with no error.
- **The test core.** The test core's own description says it "rumbles port
  1's large motor while Cross is held". So holding Cross on the controller at
  port 1 must reach the core through `input`, and the core's vibration must
  come back to that controller's motors at full strength, then stop when
  Cross is let go. The menu then steps the core's `fake_color` option from
  Blue to Green, and the picture turns green. Choosing the second disc of a
  two-disc `.m3u` ends with `discs.inserted` at 1, not busy and not failed.

Both cases passed on Windows on 13 November 2026, with the host built from
the host repository's `stage2-gpu` branch (bde086e) with WinLibs GCC 15.2,
and SwanStation built for Windows.

## Not yet

- **Not in the game flow.** Starting a PS1 game still uses the old path.
  Still to do: switching it to `RetroHostGame`, picking the host's files, and
  the settings for using the host.
- **No keyboard.** Only controllers play a game. The keyboard layout in
  `Controls` is not turned into `input` yet.
- **No menu view.** `RetroGameMenu` is a model. The view that shows its rows,
  the button that opens it, and the loading and error screens
  (`progressLabel`, `errorCode` in the player's language) are still to do.
- **Not wired to the app.** Nothing yet makes a `RetroHostControls` from the
  app's controller reader, its Player 1 order, the dead zone setting or the
  player's volume. That comes with the game flow.
- **One copy per frame.** Each frame is copied once and uploaded through
  `decodeImageFromPixels`. A texture that shares the ring with the GPU would
  avoid the copy. That is worth doing only if a trace shows the copy costs
  frames.
