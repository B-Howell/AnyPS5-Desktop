import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';
import 'package:crypto/crypto.dart';

import 'webrtc_native_worker.dart';

/// A pinned Coco Park replay with 60 frames of stick steering during the race.
final class WebRtcCtrRace {
  WebRtcCtrRace._(this.frames);

  static const _disc = '7061d0d774c4d73bd3bc90afaa1b6d35a9fcdd797c5d92d973af55423e2ce59f';
  static const _trace = '1ebe8ea9404caae28caec484e2bd1dc2b0fd7c67c47fcb8810aad6667e59d9c6';
  static const _firstStickFrame = 6600;
  static const _endStickFrame = 6660;
  final List<Ps1FrameInputs> frames;

  static Future<WebRtcCtrRace> load(String path, String disc) async {
    final file = File(path);
    if (disc != _disc || await file.length() > 65536) {
      throw const FormatException('Use the pinned CTR USA disc and Coco Park trace.');
    }
    final source = (await file.readAsString()).trim();
    if (sha256.convert(utf8.encode(source)).toString() != _trace) {
      throw const FormatException('The Coco Park trace failed verification.');
    }
    final frames = <Ps1FrameInputs>[];
    for (final span in (jsonDecode(source) as List).cast<List<dynamic>>()) {
      final [count, first, second] = span.cast<int>();
      for (var i = 0; i < count; i++) {
        final analog = frames.length >= _firstStickFrame && frames.length < _endStickFrame;
        frames.add((_pad(first, analog), _pad(second, analog)));
      }
    }
    return WebRtcCtrRace._(frames);
  }

  static Ps1PadInput _pad(int buttons, bool analog) => (
    buttons: analog ? buttons & ~192 : buttons,
    leftX: analog ? 32767 * ((buttons & 128 != 0 ? 1 : 0) - (buttons & 64 != 0 ? 1 : 0)) : 0,
    leftY: 0,
    rightX: 0,
    rightY: 0,
  );

  Future<File> writeSeat(Directory work, int seat) async {
    final file = File('${work.path}/seat-$seat.trace');
    final rows = [
      for (final pair in frames)
        if (seat == 0) '${pair.$1.buttons} ${pair.$1.leftX} 0 0 0' else '${pair.$2.buttons} ${pair.$2.leftX} 0 0 0',
    ];
    return file.writeAsString(rows.join('\n'));
  }

  CtrRaceReceipt receipt() => CtrRaceReceipt(this);
}

final class CtrRaceReceipt {
  CtrRaceReceipt(this.race);

  final WebRtcCtrRace race;
  bool _checkedSticks = false;
  String? finish;
  String? finalFingerprint;

  Future<void> record(WebRtcNativeWorker worker, int frame) async {
    if (!_checkedSticks && frame >= WebRtcCtrRace._endStickFrame) {
      const first = WebRtcCtrRace._firstStickFrame;
      final history = (await worker.readHistory(first, frame)).frames;
      for (var i = 0; i < WebRtcCtrRace._endStickFrame - first; i++) {
        if (i >= history.length || history[i] != race.frames[first + i]) {
          throw StateError('CTR stick trace differed in native history at frame ${first + i}.');
        }
      }
      _checkedSticks = true;
    }
    if (frame == race.frames.length && finish == null) {
      finalFingerprint = await worker.readFingerprint();
      finish = await _readFinish(worker);
    }
  }

  // Game-owned result fields from the pinned CTR fixture in determinism.py.
  Future<String> _readFinish(WebRtcNativeWorker worker) async {
    const tracker = 0x096B20;
    Future<ByteData> read(int address, int size) async => ByteData.sublistView(await worker.readRam(address, size));
    final mode = (await read(tracker, 4)).getUint32(0, Endian.little);
    final players = (await read(tracker + 0x1CA8, 1)).getUint8(0);
    final laps = (await read(tracker + 0x1D33, 1)).getUint8(0);
    if (mode & 0x200000 == 0 || players != 2 || laps != 3) {
      throw StateError('CTR did not show the end of a three-lap two-player race.');
    }
    final drivers = await read(tracker + 0x24EC, 8);
    final ranks = <int>{};
    final results = <String>[];
    var winnerCompleted = false;
    for (final index in [0, 4]) {
      final pointer = drivers.getUint32(index, Endian.little);
      final driver = pointer & 0x1FFFFF;
      if (pointer < 0x80000000 || pointer >= 0x80200000 || driver == 0 || driver >= 0x200000 - 0x484) {
        throw StateError('CTR returned an invalid driver pointer.');
      }
      final lap = (await read(driver + 0x44, 1)).getUint8(0);
      final flags = (await read(driver + 0x2C8, 4)).getUint32(0, Endian.little);
      final rank = (await read(driver + 0x482, 2)).getInt16(0, Endian.little) + 1;
      if (flags & 0x02000000 == 0) throw StateError('CTR did not produce two finished placements.');
      ranks.add(rank);
      winnerCompleted |= rank == 1 && lap == laps;
      results.add('rank $rank, lap $lap');
    }
    if (!ranks.containsAll([1, 2]) || !winnerCompleted) throw StateError('CTR placements are incomplete.');
    return results.join(' / ');
  }
}
