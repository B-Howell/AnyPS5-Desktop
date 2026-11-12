import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_button_map.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/retro_controls_art.dart';
import 'package:anyps5_desktop/ui/retro_pad_art.dart';
import 'package:anyps5_desktop/ui/retro_pad_art_view.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';
import '../support/ui_support.dart';

/// Writes what a test draws into ANYPS5_SCREENSHOT_DIR, for looking at a screen while working on
/// it. Nothing is compared, so the pictures are not goldens and none are kept in the repository.
class _Screenshots extends GoldenFileComparator {
  _Screenshots(this.folder);

  final Directory folder;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    File(p.join(folder.path, p.basename(golden.path))).writeAsBytesSync(imageBytes);
    return true;
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async => compare(imageBytes, golden);
}

Future<void> screenshot(Finder finder, String name) async {
  final folder = Platform.environment['ANYPS5_SCREENSHOT_DIR'];
  if (folder == null) return;
  final before = goldenFileComparator;
  goldenFileComparator = _Screenshots(Directory(folder)..createSync(recursive: true));
  try {
    await expectLater(finder, matchesGoldenFile('$name.png'));
  } finally {
    goldenFileComparator = before;
  }
}

void main() {
  final art = RetroPadArt.parse(File(RetroPadArt.asset).readAsStringSync());
  const pad = PadInfo(id: 'sdl0', name: 'DualSense Wireless Controller', kind: PadKind.dualSense, connection: PadConnection.usb, driver: 'SDL');
  const hold = Duration(milliseconds: 600);

  Fixture withGames() {
    final environment = <String, String>{};
    final fixture = makeFixture(environment: environment);
    environment['ANYPS5_LIBRETRO_HOME'] = fixture.temp.path;
    installFixtureCore(fixture.temp.path, fixture.model.embeddedCoreHost, RetroPlatform.ps1);
    for (final (name, title) in [('First', 'TEST12345'), ('Second', 'TEST67890')]) {
      final folder = Directory(p.join(fixture.model.root!, name))..createSync();
      File(p.join(folder.path, 'one.cue')).createSync();
      File(p.join(folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({'platform': 'ps1', 'titleId': title, 'name': name, 'disc': 'one.cue'}),
      );
    }
    fixture.model.rescan();
    fixture.model.controllers.preview([pad], playerOne: pad.id, states: const {});
    return fixture;
  }

  void openControls(AppModel model, String game) {
    model.selected = model.games.indexWhere((candidate) => candidate.name == game);
    model.open(Layer.controls);
  }

  List<PanelRow> rows(AppModel model) => model.panelCategories().single.rows;
  PanelRow row(AppModel model, String id) => rows(model).singleWhere((row) => row.id == id);
  String focused(AppModel model) => rows(model)[model.panelRow].id;
  void press(AppModel model, PadButton button, {required bool down}) =>
      model.captureRetroButton(PadButtonEvent(pad.id, button, down: down));

  test('the controller drawing has a shape for every input', () {
    for (final button in RetroButtonMap.buttons) {
      expect(art.boundsOf(button), isNotNull, reason: button.name);
    }
    expect(
      {...RetroButtonMap.leftSide, ...RetroButtonMap.rightSide, ...RetroButtonMap.topSide},
      RetroButtonMap.buttons.toSet(),
      reason: 'every input has a label on one side',
    );
    expect(art.shapes.where((shape) => shape.id == 'btn-ps').single.only, 'ps');
    expect(art.shapes.where((shape) => shape.id == 'btn-analog').single.only, 'analog');
    expect(RetroPadArt.buttonOf('sym-cross'), PadButton.south);
    expect(RetroPadArt.buttonOf('btn-ps'), PadButton.guide);
  });

  test('a path with relative and smooth curve commands is read', () {
    final bounds = parsePathData('M10,10 h20 v10 l-20,0 z m40,0 c5,0 10,5 10,10 s5,10 10,10').getBounds();
    expect(bounds.left, 10);
    expect(bounds.right, closeTo(70, 0.5));
    expect(() => parsePathData('M0,0 X5'), throwsFormatException);
  });

  testWidgets('a held button takes a label over, a tap does not, and Back or waiting cancels', (tester) async {
    final fixture = withGames();
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    openControls(model, 'First');
    final game = model.selectedGame!;
    expect(rows(model).where((row) => row.id.startsWith('retroButton-')).length, RetroButtonMap.buttons.length);

    model.startRetroCapture(PadButton.south);
    expect(model.retroCapture, PadButton.south);
    expect(focused(model), 'retroButton-south');

    press(model, PadButton.dpadDown, down: true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(model.retroCaptureHeld, PadButton.dpadDown);
    press(model, PadButton.dpadDown, down: false);
    await tester.pump(hold);
    expect(model.retroCapture, PadButton.south, reason: 'a tap while waiting changes nothing');
    expect(model.retroLayout(game, 1), RetroButtonMap.standard);

    press(model, PadButton.l1, down: true);
    await tester.pump(hold);
    expect(model.retroCapture, isNull);
    final layout = model.retroLayout(game, 1);
    expect(layout.source(PadButton.south), PadButton.l1);
    expect(layout.source(PadButton.l1), PadButton.south);
    expect(model.toast, 'Cross is now on L1');

    model.startRetroCapture(PadButton.north);
    press(model, PadButton.east, down: true);
    await tester.pump(const Duration(milliseconds: 100));
    press(model, PadButton.east, down: false);
    expect(model.retroCapture, isNull, reason: 'a tap of Back cancels');
    expect(model.retroLayout(game, 1), layout);

    model.startRetroCapture(PadButton.north);
    press(model, PadButton.east, down: true);
    await tester.pump(hold);
    expect(model.retroLayout(game, 1).source(PadButton.north), PadButton.east, reason: 'held, Back can be given away too');

    model.startRetroCapture(PadButton.start);
    await tester.pump(AppModel.retroCaptureWait + const Duration(milliseconds: 100));
    expect(model.retroCapture, isNull, reason: 'the wait ends by itself');

    model.startRetroCapture(PadButton.start);
    model.handle(Command.down);
    expect(focused(model), 'retroButton-start', reason: 'nothing moves the focus while a label waits');
    model.handle(Command.back);
    expect(model.retroCapture, isNull);
    expect(model.overlay, Layer.controls);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the page opens on a label and the focus moves as things sit on the screen', (tester) async {
    final fixture = withGames();
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    openControls(model, 'First');
    expect(focused(model), 'retroButton-south', reason: 'the page opens on the controller');

    model.panelCommand(Command.up);
    expect(focused(model), 'retroButton-east');
    model.panelCommand(Command.left);
    expect(focused(model), 'retroButton-dpadLeft');
    model.panelCommand(Command.left);
    expect(focused(model), 'retroButton-dpadLeft', reason: 'nothing is left of the left-hand labels');
    for (var step = 0; step < 4; step++) {
      model.panelCommand(Command.up);
    }
    expect(focused(model), 'retroButton-select');
    model.panelCommand(Command.right);
    expect(focused(model), 'retroButton-start');
    model.panelCommand(Command.right);
    expect(focused(model), 'retroButton-r2');

    model.panelCommand(Command.right);
    expect(focused(model), 'retroControlsPlayer', reason: 'right of the right-hand labels is the list');
    model.panelCommand(Command.left);
    expect(focused(model), 'retroControlsPlayer', reason: 'left steps a row that has a value');
    model.panelCommand(Command.up);
    expect(focused(model), 'retroButton-r2', reason: 'up from the first row is back on the controller');

    for (var step = 0; step < 6; step++) {
      model.panelCommand(Command.down);
    }
    expect(focused(model), 'retroButton-r3');
    model.panelCommand(Command.down);
    expect(focused(model), 'retroControlsPlayer', reason: 'below the last label is the list');

    final last = rows(model).lastIndexWhere((row) => !row.id.startsWith('retroButton-'));
    model.panelRow = last;
    model.panelCommand(Command.down);
    expect(model.panelRow, last, reason: 'the list ends at its last row');
    model.panelCommand(Command.left);
    expect(focused(model), 'retroButton-r3', reason: 'left from a row with no value is back on the last label');

    T.language = Language.byCode('ar');
    addTearDown(() => T.language = Language.english);
    model.handle(Command.left);
    expect(focused(model), 'retroButton-l3', reason: 'mirrored, the controller is not: left is still left on it');
    model.handle(Command.right);
    expect(focused(model), 'retroButton-r3');
    model.handle(Command.right);
    expect(focused(model), 'retroButton-r3', reason: 'mirrored, the list is on the other side');
    model.handle(Command.left);
    model.handle(Command.left);
    expect(focused(model), 'retroControlsPlayer', reason: 'left of the left-hand labels is the list');
    model.handle(Command.up);
    expect(focused(model), 'retroButton-l3', reason: 'and up from the first row is back on the controller');
    for (var step = 0; step < 7; step++) {
      model.handle(Command.up);
    }
    expect(focused(model), 'retroButton-select');
    model.handle(Command.right);
    expect(focused(model), 'retroButton-start', reason: 'mirrored, right of Select is still Start');
    model.handle(Command.left);
    expect(focused(model), 'retroButton-select');
    model.handle(Command.left);
    expect(focused(model), 'retroButton-l2', reason: 'and left of Select is L2, not the list');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a wait never outlives the page, the controller or its six seconds', (tester) async {
    final fixture = withGames();
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    openControls(model, 'First');
    final game = model.selectedGame!;
    void send(String id, PadButton button, {required bool down}) =>
        model.debugPadEvent(PadButtonEvent(id, button, down: down));

    model.startRetroCapture(PadButton.south);
    send(pad.id, PadButton.l1, down: true);
    model.closeOverlay();
    await tester.pump(hold);
    expect(model.retroCapture, isNull);
    expect(model.retroLayout(game, 1), RetroButtonMap.standard, reason: 'leaving the page drops a hold in progress');

    openControls(model, 'First');
    model.startRetroCapture(PadButton.south);
    send(pad.id, PadButton.l1, down: true);
    model.debugPadEvent(PadGone(pad.id));
    await tester.pump(hold);
    expect(model.retroCapture, isNull);
    expect(model.retroLayout(game, 1), RetroButtonMap.standard, reason: 'a controller that goes away cannot finish its hold');

    model.startRetroCapture(PadButton.south);
    send('other', PadButton.l1, down: true);
    await tester.pump(hold);
    expect(model.retroCapture, PadButton.south, reason: "another controller's button is not this player's");
    expect(model.retroLayout(game, 1), RetroButtonMap.standard);
    send('other', PadButton.east, down: true);
    send('other', PadButton.east, down: false);
    expect(model.retroCapture, isNull, reason: 'Back on any controller cancels');

    model.startRetroCapture(PadButton.south);
    for (var second = 0; second < 5; second++) {
      await tester.pump(const Duration(seconds: 1));
      send(pad.id, PadButton.dpadUp, down: true);
      send(pad.id, PadButton.dpadUp, down: false);
    }
    expect(model.retroCapture, PadButton.south);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(model.retroCapture, isNull, reason: 'taps do not push the six seconds back');

    model.startRetroCapture(PadButton.south);
    send(pad.id, PadButton.east, down: true);
    send(pad.id, PadButton.l1, down: true);
    send(pad.id, PadButton.east, down: false);
    await tester.pump(hold);
    expect(model.retroCapture, isNull);
    expect(model.retroLayout(game, 1), RetroButtonMap.standard, reason: 'a Back tap cancels even with another button held');

    model.startRetroCapture(PadButton.south);
    send(pad.id, PadButton.r1, down: true);
    model.rescan();
    await tester.pump(hold);
    expect(model.retroLayout(model.selectedGame!, 1).source(PadButton.south), PadButton.r1, reason: 'a library scan does not drop a hold');
    model.preferences.retroControls.useLayout(game.id, RetroButtonMap.standard);

    model.startRetroCapture(PadButton.south);
    final waiting = model.panelRow;
    model.hoverRow(0);
    expect(model.panelRow, waiting, reason: 'the pointer passing over a row leaves a waiting label alone');
    model.setRowValue(0, 0);
    expect(model.retroCapture, isNull, reason: 'a click elsewhere ends the wait');
    model.preferences.retroControls.edit(game.id, RetroButtonMap.swapCrossCircle);
    model.startRetroCapture(PadButton.south);
    model.activateRow(rows(model).indexWhere((row) => row.id == 'retroControlsReset'));
    expect(model.retroCapture, isNull);
    expect(model.retroLayout(game, 1), RetroButtonMap.swapCrossCircle, reason: 'a row reached while a label waits ends the wait and does nothing more');
    model.preferences.retroControls.useLayout(game.id, RetroButtonMap.standard);

    model.startRetroCapture(PadButton.south);
    send(pad.id, PadButton.l1, down: true);
    await tester.pump(hold);
    expect(model.retroLayout(game, 1).source(PadButton.south), PadButton.l1);
    expect(focused(model), 'retroButton-south', reason: 'the focus stays on its label when Save as a profile appears');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('with a controller, left always goes back to the labels and a chosen row keeps its directions', (tester) async {
    final fixture = withGames();
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    openControls(model, 'First');
    expect(focused(model), 'retroButton-south');
    expect(rows(model).map((row) => row.id), isNot(contains('padTest')), reason: 'the controller test is not on this page');

    model.padCommand(PadCommand.right);
    expect(focused(model), 'retroControlsPlayer', reason: 'right of the right-hand labels is the list');
    model.padCommand(PadCommand.left);
    expect(focused(model), 'retroButton-south', reason: 'left goes back, from a row with a value too');

    model.padCommand(PadCommand.right);
    model.padCommand(PadCommand.down);
    expect(focused(model), 'retroControlsPreset');
    model.padCommand(PadCommand.left);
    expect(focused(model), 'retroButton-south');

    model.padCommand(PadCommand.right);
    model.padCommand(PadCommand.select);
    expect(model.editingValue, 'retroControlsPlayer', reason: 'choosing a row is what lets its value change');
    model.padCommand(PadCommand.right);
    expect(model.retroControlsPlayer, 2);
    expect(focused(model), 'retroControlsPlayer');
    model.padCommand(PadCommand.left);
    expect(model.retroControlsPlayer, 1, reason: 'while it is chosen, left and right are the value');
    expect(focused(model), 'retroControlsPlayer');
    model.padCommand(PadCommand.select);
    expect(model.editingValue, isNull);
    model.padCommand(PadCommand.select);
    model.padCommand(PadCommand.back);
    expect(model.editingValue, isNull, reason: 'Back ends changing a value');
    expect(model.overlay, Layer.controls, reason: 'and does not leave the page with it');
    model.padCommand(PadCommand.left);
    expect(focused(model), 'retroButton-south', reason: 'and afterwards left goes back again');

    final first = model.selectedGame!;
    model.preferences.retroControls.edit(first.id, RetroButtonMap.standard.give(PadButton.north, PadButton.r1));
    model.refresh();
    model.panelRow = rows(model).indexWhere((row) => row.id == 'retroProfileSave');
    model.padCommand(PadCommand.select);
    expect(model.preferences.retroControlProfiles.keys, ['Profile 1']);
    expect(focused(model), 'retroControlsPreset', reason: 'the row that went leaves the focus on Profile, not on what took its place');
    model.panelRow = rows(model).indexWhere((row) => row.id == 'retroProfileRename');
    model.padCommand(PadCommand.select);
    expect(model.editingRow, isNull, reason: 'a controller cannot type a name, so it is not put in the field');
    expect(model.toast, 'Use a keyboard to rename a profile.');
    model.padCommand(PadCommand.down);
    expect(focused(model), 'retroProfileDelete', reason: 'and it can move on');
    model.padCommand(PadCommand.select);
    expect(model.preferences.retroControlProfiles, isEmpty);
    expect(focused(model), 'retroControlsPreset');
    model.preferences.retroControls.useLayout(first.id, RetroButtonMap.standard);
    model.refresh();

    model.padCommand(PadCommand.left);
    model.panelRow = rows(model).length - 1;
    model.padCommand(PadCommand.nextGame);
    model.padCommand(PadCommand.previousGame);
    expect(model.overlay, Layer.controls);
    expect(focused(model), startsWith('retroButton-'), reason: "another game's Controls put the focus back on a label");

    const guest = PadInfo(id: 'sdl1', name: 'DualShock 4', kind: PadKind.dualShock4, connection: PadConnection.usb, driver: 'SDL');
    model.controllers.preview([guest, pad], playerOne: guest.id, states: const {});
    model.localSeatPads.add(guest.id);
    expect(model.retroControlsPadId, pad.id, reason: "Player 1's controller is never one seated as another player");
    model.debugPadEvent(PadButtonEvent(guest.id, PadButton.dpadDown, down: true));
    model.debugPadEvent(PadButtonEvent(guest.id, PadButton.dpadDown, down: false));
    expect(model.retroControlsPadId, pad.id, reason: 'nor when that one has just moved the focus');
    final shown = model.selectedGame!;
    model.startRetroCapture(PadButton.south);
    model.debugPadEvent(PadButtonEvent(guest.id, PadButton.l1, down: true));
    await tester.pump(AppModel.retroCaptureHold + const Duration(milliseconds: 50));
    expect(model.retroCapture, PadButton.south);
    expect(model.retroLayout(shown, 1), RetroButtonMap.standard, reason: "and its held button is not Player 1's");
    model.debugPadEvent(PadButtonEvent(guest.id, PadButton.l1, down: false));
    model.cancelRetroCapture();
    model.controllers.preview([guest], playerOne: guest.id, states: const {});
    model.startRetroCapture(PadButton.south);
    expect(model.retroCapture, isNull, reason: 'with no controller for the player shown nothing waits');
    expect(model.toast, 'Player 1 has no controller connected.');
    model.localSeatPads.clear();
    model.controllers.preview([pad], playerOne: pad.id, states: const {});
    model.padCommand(PadCommand.right);
    model.padCommand(PadCommand.left);
    expect(focused(model), startsWith('retroButton-'));
    while (focused(model) != 'retroButton-south') {
      model.padCommand(PadCommand.down);
      if (focused(model) == 'retroButton-r3') break;
    }
    if (focused(model) != 'retroButton-south') {
      for (var step = 0; step < 2; step++) {
        model.padCommand(PadCommand.up);
      }
    }
    expect(focused(model), 'retroButton-south');

    for (final step in [PadCommand.up, PadCommand.up, PadCommand.left, PadCommand.down]) {
      model.padCommand(step);
    }
    expect(focused(model), 'retroButton-dpadLeft', reason: 'among the labels the directions follow the screen');
    model.padCommand(PadCommand.select);
    expect(model.retroCapture, PadButton.dpadLeft, reason: 'choosing a label makes it wait');
    model.padCommand(PadCommand.down);
    expect(focused(model), 'retroButton-dpadLeft');
    model.cancelRetroCapture();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the page draws the controller with a label for every input', (tester) async {
    final fixture = withGames();
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final first = model.games.singleWhere((game) => game.name == 'First');
    model.preferences.retroControls.edit(first.id, RetroButtonMap.standard.give(PadButton.south, PadButton.l1));
    openControls(model, 'First');
    expect(focused(model), 'retroButton-south');
    model.controllers.preview([pad], playerOne: pad.id, states: const {'sdl0': PadState(pressed: {PadButton.l1}, leftX: 0.8, leftY: -0.5, r2: 0.5)});
    await pumpLauncher(tester, model);
    expect(find.byType(RetroPadArtView), findsOneWidget);
    expect(find.text('L1 acts as Cross · R2 acts as R2'), findsOneWidget);
    expect(find.text('Change buttons'), findsNothing);
    expect(find.textContaining('Always use'), findsNothing);
    expect(find.byKey(const ValueKey('row-retroButton-south')), findsNothing, reason: 'the inputs are labels, not rows in the list');
    await screenshot(find.byType(MaterialApp), 'retro_controls_ps1');

    model.startRetroCapture(PadButton.north);
    press(model, PadButton.r1, down: true);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Hold a button…'), findsOneWidget);
    expect(find.text('Hold the button that should be Triangle. Tap Circle to cancel.'), findsOneWidget);
    await screenshot(find.byType(MaterialApp), 'retro_controls_ps1_waiting');
    press(model, PadButton.r1, down: false);

    final game = model.selectedGame!;
    final before = model.retroLayout(game, 1);
    press(model, PadButton.r1, down: true);
    expect(find.text('Test buttons and sticks'), findsNothing);
    await tester.tapAt(tester.getCenter(find.text('Reset to standard layout')));
    await tester.pump(hold);
    expect(model.retroCapture, isNull, reason: 'a click ends the wait');
    expect(model.retroLayout(game, 1), before, reason: 'and does nothing else: no reset, no late assignment');

    // No frame between the label being chosen and the click: the screen has not drawn the wait.
    model.startRetroCapture(PadButton.north);
    await tester.tapAt(tester.getCenter(find.text('Reset to standard layout')));
    await tester.pump();
    expect(model.retroCapture, isNull);
    expect(model.retroLayout(game, 1), before, reason: 'a click before the next frame is spent on ending the wait too');

    model.startRetroCapture(PadButton.north);
    await tester.pump();
    final right = await tester.startGesture(
      tester.getCenter(find.text('Swap left and right sticks')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.up();
    await tester.pump();
    expect(model.retroCapture, isNull);
    expect(model.overlay, Layer.controls, reason: 'the right button ends the wait and is not Back as well');

    model.startRetroCapture(PadButton.north);
    await tester.pump();
    press(model, PadButton.r1, down: true);
    final outside = await tester.startGesture(const Offset(8, 8));
    await tester.pump(hold);
    expect(model.retroCapture, isNull, reason: 'pressing outside the panel ends the wait as the button goes down');
    expect(model.retroLayout(game, 1), before);
    await outside.up();
    await tester.pump();
    expect(model.overlay, Layer.controls, reason: 'that click does not also close the page');

    model.startRetroCapture(PadButton.north);
    press(model, PadButton.r1, down: true);
    model.windowChangedFullscreen(true);
    await tester.pump(hold);
    expect(model.retroCapture, isNull);
    expect(model.retroLayout(game, 1), before, reason: "the title bar's Maximize ends the wait");

    model.startRetroCapture(PadButton.north);
    press(model, PadButton.r1, down: true);
    tester.view.physicalSize = const Size(1500, 880);
    await tester.pump();
    await tester.pump(hold);
    expect(model.retroCapture, isNull);
    expect(model.retroLayout(game, 1), before, reason: 'so does the window changing size');
    tester.view.physicalSize = const Size(1600, 900);
    await tester.pump();

    model.startRetroCapture(PadButton.north);
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.byType(BackPill)));
    await tester.pump();
    expect(model.retroCapture, isNull);
    expect(model.overlay, Layer.controls, reason: 'nor does a click on Back');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('each console draws its own controller', (tester) async {
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = const Size(1500, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          color: const Color(0xFF171A22),
          child: Column(
            children: [
              for (final platform in RetroPlatform.values)
                Expanded(
                  child: Center(
                    child: RetroPadArtView(
                      art: art,
                      platform: platform,
                      labelScale: 1.6,
                      accent: const Color(0xFF4DA3FF),
                      lit: const {PadButton.south: 1, PadButton.l2: 0.5, PadButton.dpadUp: 1, PadButton.guide: 1},
                      leftStick: const Offset(0.8, -0.5),
                      callouts: [
                        for (final button in RetroButtonMap.buttons)
                          PadCallout(
                            button: button,
                            label: button == PadButton.r1 ? 'Hold a button…' : button.name,
                            changed: button == PadButton.north,
                            focused: button == PadButton.east,
                            waiting: button == PadButton.r1,
                            progress: button == PadButton.r1 ? 0.6 : 0,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(RetroPadArtView), findsNWidgets(3));
    expect(find.text('Hold a button…'), findsNWidgets(3));
    await screenshot(find.byType(MaterialApp), 'retro_controls_consoles');
  });

  testWidgets('a drawing that cannot be read leaves every label to click, inside the page', (tester) async {
    final fixture = withGames();
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    openControls(model, 'First');
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Center(
            child: SizedBox(
              width: 830,
              height: 560,
              child: RetroControlsArt(model: model, loadArt: () => Future.error(const FormatException('unreadable'))),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'the plain controller and its labels fit the pane');
    expect(find.byType(RetroPadArtView), findsNothing);
    expect(find.text('Cross: Cross'), findsOneWidget);
    expect(find.text('R3: R3'), findsOneWidget);
    await tester.tap(find.text('Triangle: Triangle'));
    expect(model.retroCapture, PadButton.north);
    model.cancelRetroCapture();
    await screenshot(find.byType(MaterialApp), 'retro_controls_unreadable');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a pane too narrow for labels draws the controller alone', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: RetroPadArtView(
              art: art,
              platform: RetroPlatform.ps2,
              accent: const Color(0xFF4DA3FF),
              callouts: const [PadCallout(button: PadButton.south, label: 'Cross')],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Cross'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('a profile is saved and each game remembers the one chosen on its page', () {
    final fixture = withGames();
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    openControls(model, 'First');
    final first = model.selectedGame!;
    final second = model.games.singleWhere((game) => game.name == 'Second');
    final controls = model.preferences.retroControls;
    final custom = RetroButtonMap.standard.give(PadButton.south, PadButton.l1);
    expect(rows(model).map((row) => row.id), isNot(contains('retroControlsOwn')));
    expect(rows(model).map((row) => row.id), isNot(contains('retroControlsLabels')));

    controls.edit(first.id, custom);
    expect(model.retroLayout(first, 1), custom);
    expect(model.retroLayout(second, 1), RetroButtonMap.standard, reason: 'another game is not changed');
    expect((row(model, 'retroControlsPreset').kind as ChoiceRow).options.last, 'Custom');

    (row(model, 'retroProfileSave').kind as ActionRow).run();
    expect(model.preferences.retroControlProfiles.keys, ['Profile 1']);
    final preset = row(model, 'retroControlsPreset').kind as ChoiceRow;
    expect(preset.options, ['Standard', 'Swap Cross and Circle', 'Profile 1']);
    expect(preset.selected, 2);

    (row(model, 'retroProfileRename').kind as TextRow).set('Racing');
    expect(model.preferences.retroControlProfiles.keys, ['Racing']);
    expect(model.preferences.retroProfileChoice, {first.id: 'Racing'});

    openControls(model, 'Second');
    final secondPreset = row(model, 'retroControlsPreset').kind as ChoiceRow;
    expect(secondPreset.options, ['Standard', 'Swap Cross and Circle', 'Racing'], reason: 'a saved profile is offered to every game');
    expect(secondPreset.selected, 0);
    secondPreset.set(2);
    expect(model.retroLayout(second, 1), custom);

    final again = Preferences.fromJson(jsonDecode(jsonEncode(model.preferences.toJson())) as Map<String, dynamic>);
    expect(again.retroControls.resolve(first.id, 1), custom);
    expect(again.retroControls.resolve(second.id, 1), custom);
    expect(again.retroControls.names, ['Racing']);

    (row(model, 'retroControlsPreset').kind as ChoiceRow).set(1);
    expect(model.retroLayout(second, 1), RetroButtonMap.swapCrossCircle);
    expect(model.retroLayout(first, 1), custom, reason: 'the first game keeps its profile');

    openControls(model, 'First');
    controls.useProfile('${first.id}#p2', 'Racing');
    (row(model, 'retroProfileDelete').kind as ActionRow).run();
    expect(model.preferences.retroControlProfiles, isEmpty);
    expect(model.preferences.retroProfileChoice, isEmpty);
    expect(model.retroLayout(first, 1), RetroButtonMap.standard);
    expect(model.retroLayout(first, 2), RetroButtonMap.standard);
    expect(model.retroLayout(second, 1), RetroButtonMap.swapCrossCircle);
  });

  test('choosing a saved profile leaves an unsaved layout to come back to', () {
    final preferences = Preferences.fromJson(const {});
    final controls = preferences.retroControls;
    final custom = RetroButtonMap.standard.give(PadButton.north, PadButton.r1);
    controls.saved['Racing'] = RetroButtonMap.swapCrossCircle;
    controls.edit('game', custom);
    controls.useProfile('game', 'Racing');
    expect(controls.layoutOf('game'), RetroButtonMap.swapCrossCircle);
    controls.useOwnLayout('game');
    expect(controls.layoutOf('game'), custom);
    expect(controls.freeName((number) => 'Profile $number'), 'Profile 1');
    controls.saved['Profile 1'] = custom;
    controls.saved['Profile 3'] = custom;
    expect(controls.freeName((number) => 'Profile $number'), 'Profile 2');
  });

  test('layouts saved before profiles are read as they were', () {
    final preferences = Preferences.fromJson({
      'retroSwapCrossCircle': ['one'],
      'retroButtonMaps': {
        'two#p2': {'l1': 'r1'},
      },
    });
    expect(preferences.retroControls.resolve('one', 1), RetroButtonMap.swapCrossCircle);
    expect(preferences.retroControls.resolve('two', 2).target(PadButton.l1), PadButton.r1);
    expect(preferences.retroControls.resolve('two', 1), RetroButtonMap.standard);
    expect(preferences.retroControls.resolve('three', 1), RetroButtonMap.standard);
  });

  test('giving an input a button trades the two, and Not used leaves it without one', () {
    final swapped = RetroButtonMap.standard.give(PadButton.south, PadButton.east);
    expect(swapped, RetroButtonMap.swapCrossCircle);
    expect(swapped.give(PadButton.south, PadButton.south), RetroButtonMap.standard);
    final unused = RetroButtonMap.standard.give(PadButton.select, null);
    expect(unused.source(PadButton.select), isNull);
    expect(unused.target(PadButton.select), isNull);
    expect(unused.give(PadButton.select, PadButton.select), RetroButtonMap.standard);
  });

  test('an older layout with two buttons on one input ends with one', () {
    final doubled = RetroButtonMap.standard.assign(PadButton.south, PadButton.east);
    expect(doubled.sources(PadButton.east), [PadButton.south, PadButton.east]);
    final given = doubled.give(PadButton.east, PadButton.north);
    expect(given.sources(PadButton.east), [PadButton.north]);
    expect(given.target(PadButton.south), PadButton.north, reason: 'the first of the two takes over what the new button did');
    expect(given.target(PadButton.east), isNull, reason: 'the other is left unused, and its label says so');
    expect(doubled.give(PadButton.east, PadButton.east).sources(PadButton.east), [PadButton.east]);
    expect(doubled.give(PadButton.east, null).sources(PadButton.east), isEmpty);
  });
}
