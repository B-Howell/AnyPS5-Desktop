/// Lockstep, the first step of PS1 online play through the emulator host (anyps5-retro-host
/// docs/protocol.md "Lockstep", capability `ps1Lockstep`), and rollback on top of it ("Rollback",
/// capability `ps1Rollback`): what the launcher sends, what it reads back, and the rules that tie
/// the two together, as the client checks them.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'retro_host_protocol.dart';
import 'retro_pad.dart';

/// The capability that adds `start.lockstep`, the methods `lockstep`, `saveState` and `loadState`,
/// and the messages `step` and `sync`.
const retroCapabilityPs1Lockstep = 'ps1Lockstep';

/// The capability that adds rollback to lockstep: `lockstep.rollback`, `null` ports in `step`, and
/// the messages `correct` and `rollback`. A host lists it only with [retroCapabilityPs1Lockstep].
const retroCapabilityPs1Rollback = 'ps1Rollback';

/// The methods only a host with [retroCapabilityPs1Lockstep] has.
const retroLockstepMethods = {'lockstep', 'saveState', 'loadState'};

/// The argument of `lockstep` and of `start.lockstep` (protocol.md "lockstep").
class RetroLockstepSettings {
  const RetroLockstepSettings({required this.check, this.paced = true, this.rollback});

  /// A `sync` comes after every frame whose number is a multiple of this, 1 to 3600.
  final int check;

  /// Keeps the game to its core's frame rate even when steps queue up; false runs queued steps as
  /// fast as the machine can.
  final bool paced;

  /// With [retroCapabilityPs1Rollback], the game runs in rollback with at most this many frames,
  /// 1 to [maxRollback], stepped beyond the last confirmed one; null is plain lockstep.
  final int? rollback;

  static const maxCheck = 3600;

  /// The most frames a rollback window holds: GGPO's prediction window, and the host's limit.
  static const maxRollback = 8;

  Map<String, Object?> toArgs() {
    if (check < 1 || check > maxCheck) throw RangeError.range(check, 1, maxCheck, 'check');
    final frames = rollback;
    if (frames != null && (frames < 1 || frames > maxRollback)) {
      throw RangeError.range(frames, 1, maxRollback, 'rollback');
    }
    return {
      'check': check,
      'paced': paced,
      if (frames != null) 'rollback': {'frames': frames},
    };
  }

  /// The rollback window of a `lockstep` argument as [toArgs] writes it; null for plain lockstep.
  static int? rollbackOf(Object? args) {
    if (args is! Map) return null;
    final rollback = args['rollback'];
    if (rollback is! Map) return null;
    final frames = rollback['frames'];
    return frames is int ? frames : null;
  }
}

/// The result of `saveState` and `loadState`: the lockstep frame the state continues with, the
/// size of its file, and how long the host took, in microseconds.
class RetroStatePosition {
  const RetroStatePosition({required this.frame, required this.bytes, this.micros = 0});

  final int frame;
  final int bytes;

  /// How long the host spent saving or loading the state; not part of what a state is.
  final int micros;

  /// The largest file size a launcher accepts: 2^53, what a JSON number holds exactly.
  static const maxBytes = 9007199254740991;

  static RetroStatePosition parse(Map<String, Object?> map, String where) {
    final f = RetroFields(map, where);
    return RetroStatePosition(
      frame: f.integer('frame', 0, RetroFields.maxUint32),
      bytes: f.integer('bytes', RetroStateFile.headerBytes, maxBytes),
      micros: f.integer('micros', 0, maxBytes),
    );
  }

  @override
  bool operator ==(Object other) => other is RetroStatePosition && other.frame == frame && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(frame, bytes);

  @override
  String toString() => 'RetroStatePosition(frame $frame, $bytes bytes, $micros µs)';
}

/// The file `saveState` writes and `loadState` reads (protocol.md "saveState and loadState"): a
/// 48-byte header, then the core's data. Integers are little-endian.
class RetroStateFile {
  const RetroStateFile({required this.frame, required this.ports, required this.core});

  static const headerBytes = 48;

  /// The file's version this launcher reads: 2, the one that holds the port count.
  static const version = 2;

  static final _magic = 'AP5STATE'.codeUnits;

  /// The lockstep frame the state continues with.
  final int frame;

  /// The connected controller ports the state was saved with, 1 or 2.
  final int ports;

  /// The core's `retro_serialize` data.
  final Uint8List core;

  /// Reads [bytes] as a state file; null for anything that is not one of [version].
  static RetroStateFile? read(Uint8List bytes) {
    if (bytes.length < headerBytes) return null;
    for (var index = 0; index < _magic.length; index++) {
      if (bytes[index] != _magic[index]) return null;
    }
    final header = ByteData.sublistView(bytes, 0, headerBytes);
    final size = header.getUint64(32, Endian.little);
    final ports = header.getUint32(40, Endian.little);
    final frame = header.getUint64(16, Endian.little);
    if (header.getUint32(8, Endian.little) != version ||
        header.getUint32(12, Endian.little) > 1 ||
        frame < 0 ||
        frame > RetroFields.maxUint32 ||
        size != bytes.length - headerBytes ||
        ports < 1 ||
        ports > 2 ||
        header.getUint32(44, Endian.little) != 0) {
      return null;
    }
    return RetroStateFile(frame: frame, ports: ports, core: Uint8List.sublistView(bytes, headerBytes));
  }
}

/// A controller port's fields as `input`, `step` and `correct` carry them.
Map<String, Object?> retroPadFields(RetroPadInput port) => {
  'buttons': port.buttons,
  'leftX': port.leftX,
  'leftY': port.leftY,
  'rightX': port.rightX,
  'rightY': port.rightY,
};

/// A controller port's fields of [value], as [retroPadFields] writes them; [skip] names the other
/// fields of the message they are in.
RetroPadInput retroPadParse(Object? value, String where, {Set<String> skip = const {}}) {
  if (value is! Map<String, Object?>) throw RetroProtocolError('$where must be an object.');
  final f = RetroFields(value, where);
  for (final key in value.keys) {
    if (!skip.contains(key) && !_padKeys.contains(key)) throw RetroProtocolError('$where has an unknown field, $key.');
  }
  int axis(String key) => f.integer(key, -32768, 32767);
  return RetroPadInput(
    buttons: f.integer('buttons', 0, 0xFFFF),
    leftX: axis('leftX'),
    leftY: axis('leftY'),
    rightX: axis('rightX'),
    rightY: axis('rightY'),
  );
}

const _padKeys = {'buttons', 'leftX', 'leftY', 'rightX', 'rightY'};

/// The input of one lockstep frame (protocol.md "step"): one entry per connected port, from port 1.
/// In rollback a port may be null: its input is not known yet, so the host predicts it, and a
/// [RetroCorrect] gives it later.
class RetroStep {
  RetroStep(this.frame, List<RetroPadInput?> ports) : ports = List.unmodifiable(ports) {
    if (frame < 0 || frame > RetroFields.maxUint32) throw RangeError.range(frame, 0, RetroFields.maxUint32, 'frame');
    if (ports.isEmpty || ports.length > 2) throw RangeError.range(ports.length, 1, 2, 'ports');
  }

  final int frame;
  final List<RetroPadInput?> ports;

  Map<String, Object?> toMessage() => {
    'type': 'step',
    'frame': frame,
    'ports': [for (final port in ports) port == null ? null : retroPadFields(port)],
  };

  /// Reads a `step` as the launcher wrote it, for tests that replay recorded steps.
  static RetroStep parse(Map<String, Object?> map) {
    final f = RetroFields(map, 'step');
    final ports = map['ports'];
    if (ports is! List<Object?> || ports.isEmpty || ports.length > 2) {
      throw const RetroProtocolError('step.ports must hold 1 or 2 entries.');
    }
    return RetroStep(f.integer('frame', 0, RetroFields.maxUint32), [
      for (final port in ports) port == null ? null : retroPadParse(port, 'step.ports'),
    ]);
  }
}

/// The real input of one port in a frame whose step left it null (protocol.md "correct").
class RetroCorrect {
  RetroCorrect(this.frame, this.port, this.input) {
    if (frame < 0 || frame > RetroFields.maxUint32) throw RangeError.range(frame, 0, RetroFields.maxUint32, 'frame');
    if (port < 0 || port > 1) throw RangeError.range(port, 0, 1, 'port');
  }

  final int frame;

  /// The controller port, 0 or 1.
  final int port;
  final RetroPadInput input;

  Map<String, Object?> toMessage() => {'type': 'correct', 'frame': frame, 'port': port, ...retroPadFields(input)};

  /// Reads a `correct` as the launcher wrote it, for tests that replay recorded corrections.
  static RetroCorrect parse(Map<String, Object?> map) {
    final f = RetroFields(map, 'correct');
    return RetroCorrect(
      f.integer('frame', 0, RetroFields.maxUint32),
      f.integer('port', 0, 1),
      retroPadParse(map, 'correct', skip: const {'type', 'frame', 'port'}),
    );
  }
}

/// The host ran frames again after a wrong prediction (protocol.md "rollback message"): [frames]
/// of them from [frame], in [micros] from the start of the state's load, which took [loadMicros].
/// It is for statistics: nothing in a match depends on it.
class RetroRollback {
  const RetroRollback({required this.frame, required this.frames, required this.micros, required this.loadMicros});

  final int frame;
  final int frames;
  final int micros;
  final int loadMicros;

  static RetroRollback parse(Map<String, Object?> map) {
    final f = RetroFields(map, 'rollback');
    final micros = f.integer('micros', 0, RetroStatePosition.maxBytes);
    return RetroRollback(
      frame: f.integer('frame', 0, RetroFields.maxUint32),
      frames: f.integer('frames', 1, RetroLockstepSettings.maxRollback),
      micros: micros,
      loadMicros: f.integer('loadMicros', 0, micros),
    );
  }

  @override
  String toString() => 'RetroRollback(from $frame, $frames frames, $micros µs, load $loadMicros µs)';
}

/// What a lockstep frame left behind (protocol.md "sync"): 64-bit FNV-1a hashes as 16 lowercase
/// hexadecimal digits, null where the core cannot give them.
class RetroSync {
  const RetroSync({required this.frame, required this.ram, required this.video, required this.state});

  final int frame;

  /// The console's main RAM after the frame: the same on every machine that ran the same steps.
  final String? ram;

  /// The last picture: the same on two machines only when both draw in software.
  final String? video;

  /// The core's whole state, saved for netplay so that it names no path: the same on two machines
  /// that ran the same steps, except between two GPUs drawing above 1x (protocol.md "sync").
  final String? state;

  static final _hash = RegExp(r'^[0-9a-f]{16}$');

  static RetroSync parse(Map<String, Object?> map) {
    final f = RetroFields(map, 'sync');
    String? hash(String key) {
      final value = f.stringOrNull(key);
      if (value != null && !_hash.hasMatch(value)) {
        throw RetroProtocolError('sync.$key must be 16 lowercase hexadecimal digits or null.');
      }
      return value;
    }

    return RetroSync(
      frame: f.integer('frame', 0, RetroFields.maxUint32),
      ram: hash('ram'),
      video: hash('video'),
      state: hash('state'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RetroSync && other.frame == frame && other.ram == ram && other.video == video && other.state == state;

  @override
  int get hashCode => Object.hash(frame, ram, video, state);

  @override
  String toString() => 'RetroSync($frame, ram $ram, video $video, state $state)';
}

/// The lockstep side of one host connection: which frame the next `step` is for, whether a `sync`
/// may come, and, in rollback, which ports' input is not known yet. The client asks it before it
/// sends a step or a correction and gives it every reply of a lockstep method, every `sync` and
/// every `rollback` message, so a host that breaks the order is a protocol error and a launcher
/// that does is a programming error.
class RetroLockstepTracker {
  /// The frame the next step is for, or null while the game is not in lockstep.
  int? get nextStep => _next;
  int? _next;

  /// The connected ports of the last step sent: what the game keeps once it leaves lockstep.
  int? get lastPorts => _lastPorts;
  int? _lastPorts;

  /// The rollback window, or null in plain lockstep and outside lockstep.
  int? get rollback => _rollback;
  int? _rollback;

  /// The newest frame a `sync` came for in the current count.
  int? _lastSync;

  /// The steps sent in the current count, so a `sync` for a frame never stepped is refused.
  int? _first;

  /// Per port, the frames stepped with that port null and not corrected yet, oldest first.
  final _unknown = [Queue<int>(), Queue<int>()];

  bool get inLockstep => _next != null;

  /// The newest frame every port's input is known for, up to it, in the current count (protocol.md
  /// "Rollback": the frame is confirmed); null before the first step. In plain lockstep it is the
  /// last frame stepped.
  int? get confirmed {
    final next = _next;
    final first = _first;
    if (next == null || first == null || next == first) return null;
    var oldest = next;
    for (final unknown in _unknown) {
      if (unknown.isNotEmpty && unknown.first < oldest) oldest = unknown.first;
    }
    return oldest - 1 < first ? null : oldest - 1;
  }

  /// A game started: in lockstep at frame 0 when its `start` had `lockstep`, in rollback with its
  /// window when that had `rollback`.
  void started({required bool lockstep, int? rollback}) {
    _next = lockstep ? 0 : null;
    _first = _next;
    _lastSync = null;
    _rollback = lockstep ? rollback : null;
    _forgetUnknown();
  }

  /// No game is loaded any more.
  void ended() {
    _next = null;
    _first = null;
    _lastSync = null;
    _rollback = null;
    _forgetUnknown();
  }

  void _forgetUnknown() {
    for (final unknown in _unknown) {
      unknown.clear();
    }
  }

  /// Checks [step] is the next one and keeps rollback's rules (protocol.md "Rollback": a null port
  /// only in rollback, each port known in frame order, at most the window beyond the last
  /// confirmed frame), and counts it.
  void sending(RetroStep step) {
    final next = _next;
    if (next == null) throw StateError('A step was sent while the game is not in lockstep.');
    if (step.frame != next) throw StateError('The step for frame ${step.frame} is not the next, $next.');
    final window = _rollback;
    if (window == null && step.ports.contains(null)) {
      throw StateError('The step for frame ${step.frame} leaves a port unknown outside rollback.');
    }
    if (window != null) {
      final behind = step.frame - window;
      final confirmed = this.confirmed;
      if (behind >= _first! && (confirmed == null || confirmed < behind)) {
        throw StateError('The step for frame ${step.frame} is beyond the rollback window of $window frames.');
      }
      for (final (port, input) in step.ports.indexed) {
        if (input != null && _unknown[port].isNotEmpty) {
          throw StateError(
            'The step for frame ${step.frame} gives port $port before its frame '
            '${_unknown[port].first} is known.',
          );
        }
      }
      for (final (port, input) in step.ports.indexed) {
        if (input == null) _unknown[port].add(step.frame);
      }
    }
    _next = next + 1;
    _lastPorts = step.ports.length;
  }

  /// Checks [correct] gives the oldest unknown input of its port (protocol.md "correct"), and
  /// counts it as known.
  void correcting(RetroCorrect correct) {
    if (_rollback == null) throw StateError('A correction was sent while the game is not in rollback.');
    final unknown = _unknown[correct.port];
    if (unknown.isEmpty || unknown.first != correct.frame) {
      throw StateError(
        'The correction of port ${correct.port} in frame ${correct.frame} is not the oldest '
        'unknown input of that port${unknown.isEmpty ? '' : ', frame ${unknown.first}'}.',
      );
    }
    unknown.removeFirst();
  }

  /// A reply of `lockstep`, `saveState` or `loadState` to a call with [args]: checks it and moves
  /// the count. Gives the result as the methods' callers get it.
  Object? replied(String method, Object? args, Object? result) {
    switch (method) {
      case 'lockstep' when args == false:
        if (result is! bool) throw const RetroProtocolError('The result of lockstep false must be a boolean.');
        if (result) ended();
        return result;
      case 'lockstep':
        if (result == false) return null;
        if (result is! Map<String, Object?>) {
          throw const RetroProtocolError('The result of lockstep must be an object or false.');
        }
        final frame = RetroFields(result, 'lockstep').integer('frame', 0, RetroFields.maxUint32);
        final keeps = _next != null;
        if (keeps && frame != _next) {
          throw RetroProtocolError('lockstep.frame is $frame, not the next step $_next of the game in lockstep.');
        }
        if (!keeps && frame != 0) throw RetroProtocolError('lockstep.frame is $frame for a game entering lockstep.');
        final window = RetroLockstepSettings.rollbackOf(args);
        if (keeps && window != _rollback && _unknown.any((unknown) => unknown.isNotEmpty)) {
          throw const RetroProtocolError('lockstep changed rollback while a frame was not confirmed.');
        }
        _restart(frame, keepSyncs: keeps);
        _rollback = window;
        return frame;
      case 'saveState' || 'loadState':
        if (result == false) return null;
        if (result is! Map<String, Object?>) {
          throw RetroProtocolError('The result of $method must be an object or false.');
        }
        final position = RetroStatePosition.parse(result, method);
        if (_next == null) throw RetroProtocolError('$method gave a state for a game not in lockstep.');
        if (method == 'saveState' && _unknown.any((unknown) => unknown.isNotEmpty)) {
          throw const RetroProtocolError('saveState saved a state while a frame was not confirmed.');
        }
        if (method == 'loadState') {
          _restart(position.frame, keepSyncs: false);
          _forgetUnknown();
        }
        return position;
      default:
        throw ArgumentError.value(method, 'method', 'is not a lockstep method');
    }
  }

  void _restart(int frame, {required bool keepSyncs}) {
    _next = frame;
    if (keepSyncs) return;
    _first = frame;
    _lastSync = null;
  }

  /// A `sync`: in frame order, for a frame stepped in the current count and, in rollback,
  /// confirmed.
  RetroSync synced(Map<String, Object?> map) {
    final sync = RetroSync.parse(map);
    final next = _next;
    final first = _first;
    if (next == null || first == null) throw const RetroProtocolError('A sync came for a game not in lockstep.');
    if (sync.frame < first || sync.frame >= next) {
      throw RetroProtocolError('A sync came for frame ${sync.frame}, which was not stepped.');
    }
    final confirmed = this.confirmed;
    if (_rollback != null && (confirmed == null || sync.frame > confirmed)) {
      throw RetroProtocolError('A sync came for frame ${sync.frame}, which is not confirmed.');
    }
    final last = _lastSync;
    if (last != null && sync.frame <= last) {
      throw RetroProtocolError('A sync for frame ${sync.frame} came after the one for frame $last.');
    }
    _lastSync = sync.frame;
    return sync;
  }

  /// A `rollback` message: in rollback, for frames stepped in the current count.
  RetroRollback rolledBack(Map<String, Object?> map) {
    final rollback = RetroRollback.parse(map);
    final next = _next;
    final first = _first;
    if (_rollback == null || next == null || first == null) {
      throw const RetroProtocolError('A rollback message came for a game not in rollback.');
    }
    if (rollback.frame < first || rollback.frame + rollback.frames > next) {
      throw RetroProtocolError(
        'A rollback message ran frames ${rollback.frame} to '
        '${rollback.frame + rollback.frames - 1} again, which were not all stepped.',
      );
    }
    return rollback;
  }
}

/// What an online match uses of one emulator host: the lockstep methods, its steps and syncs, and
/// in rollback its corrections and rollback reports. [RetroHostClient] is the real one.
abstract interface class RetroLockstepHost {
  /// The host's `welcome.hostVersion`: two players' hosts must be the same release.
  String get hostVersion;

  /// Whether the host lists [retroCapabilityPs1Lockstep].
  bool get canLockstep;

  /// Whether the host lists [retroCapabilityPs1Rollback] as well.
  bool get canRollback;

  /// Whether the host lists [retroCapabilityCoreIdentity], so its `status` names the core a game
  /// loaded ([RetroStatus.core]); a match needs it of both hosts.
  bool get canIdentifyCore;

  /// Each `sync`, checked and in frame order.
  Stream<RetroSync> get syncs;

  /// Each `rollback` message, checked.
  Stream<RetroRollback> get rollbacks;

  /// `lockstep` with settings: the frame the next step is for, or null when the host could not.
  Future<int?> lockstep(RetroLockstepSettings settings);

  /// `lockstep` with `false`.
  Future<bool> leaveLockstep();

  /// `saveState` to [path]; null when the host could not.
  Future<RetroStatePosition?> saveState(String path);

  /// `loadState` from [path]; null when the host could not.
  Future<RetroStatePosition?> loadState(String path);

  /// One lockstep frame's input, the next in order.
  void step(RetroStep step);

  /// The real input of a port a step left unknown, the oldest of that port.
  void correct(RetroCorrect correct);
}
