/// Lockstep, the first step of PS1 online play through the emulator host (anyps5-retro-host
/// docs/protocol.md "Lockstep", capability `ps1Lockstep`): what the launcher sends, what it reads
/// back, and the rules that tie the two together, as the client checks them.
library;

import 'retro_host_protocol.dart';
import 'retro_pad.dart';

/// The capability that adds `start.lockstep`, the methods `lockstep`, `saveState` and `loadState`,
/// and the messages `step` and `sync`.
const retroCapabilityPs1Lockstep = 'ps1Lockstep';

/// The methods only a host with [retroCapabilityPs1Lockstep] has.
const retroLockstepMethods = {'lockstep', 'saveState', 'loadState'};

/// The argument of `lockstep` and of `start.lockstep` (protocol.md "lockstep").
class RetroLockstepSettings {
  const RetroLockstepSettings({required this.check, this.paced = true});

  /// A `sync` comes after every frame whose number is a multiple of this, 1 to 3600.
  final int check;

  /// Keeps the game to its core's frame rate even when steps queue up; false runs queued steps as
  /// fast as the machine can.
  final bool paced;

  static const maxCheck = 3600;

  Map<String, Object?> toArgs() {
    if (check < 1 || check > maxCheck) throw RangeError.range(check, 1, maxCheck, 'check');
    return {'check': check, 'paced': paced};
  }
}

/// The result of `saveState` and `loadState`: the lockstep frame the state continues with, and the
/// size of its file.
class RetroStatePosition {
  const RetroStatePosition({required this.frame, required this.bytes});

  final int frame;
  final int bytes;

  /// The largest file size a launcher accepts: 2^53, what a JSON number holds exactly.
  static const maxBytes = 9007199254740991;

  static RetroStatePosition parse(Map<String, Object?> map, String where) {
    final f = RetroFields(map, where);
    return RetroStatePosition(
      frame: f.integer('frame', 0, RetroFields.maxUint32),
      bytes: f.integer('bytes', RetroStateFile.headerBytes, maxBytes),
    );
  }

  @override
  bool operator ==(Object other) => other is RetroStatePosition && other.frame == frame && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(frame, bytes);

  @override
  String toString() => 'RetroStatePosition(frame $frame, $bytes bytes)';
}

/// The file `saveState` writes and `loadState` reads (protocol.md "saveState and loadState"): a
/// 48-byte header, then the core's data.
abstract final class RetroStateFile {
  static const headerBytes = 48;
}

/// The input of one lockstep frame (protocol.md "step"): one entry per connected port, from port 1.
class RetroStep {
  RetroStep(this.frame, List<RetroPadInput> ports) : ports = List.unmodifiable(ports) {
    if (frame < 0 || frame > RetroFields.maxUint32) throw RangeError.range(frame, 0, RetroFields.maxUint32, 'frame');
    if (ports.isEmpty || ports.length > 2) throw RangeError.range(ports.length, 1, 2, 'ports');
  }

  final int frame;
  final List<RetroPadInput> ports;

  Map<String, Object?> toMessage() => {
    'type': 'step',
    'frame': frame,
    'ports': [
      for (final port in ports)
        {
          'buttons': port.buttons,
          'leftX': port.leftX,
          'leftY': port.leftY,
          'rightX': port.rightX,
          'rightY': port.rightY,
        },
    ],
  };

  /// Reads a `step` as the launcher wrote it, for tests that replay recorded steps.
  static RetroStep parse(Map<String, Object?> map) {
    final f = RetroFields(map, 'step');
    final ports = map['ports'];
    if (ports is! List<Object?> || ports.isEmpty || ports.length > 2) {
      throw const RetroProtocolError('step.ports must hold 1 or 2 objects.');
    }
    return RetroStep(f.integer('frame', 0, RetroFields.maxUint32), [for (final port in ports) _port(port)]);
  }

  static RetroPadInput _port(Object? value) {
    if (value is! Map<String, Object?>) throw const RetroProtocolError('step.ports must hold objects.');
    final f = RetroFields(value, 'step.ports');
    int axis(String key) => f.integer(key, -32768, 32767);
    return RetroPadInput(
      buttons: f.integer('buttons', 0, 0xFFFF),
      leftX: axis('leftX'),
      leftY: axis('leftY'),
      rightX: axis('rightX'),
      rightY: axis('rightY'),
    );
  }
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

  /// The core's whole state: it also differs when the core keeps something of the machine in it,
  /// such as SwanStation's disc path.
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

/// The lockstep side of one host connection: which frame the next `step` is for, and whether a
/// `sync` may come. The client asks it before it sends a step and gives it every reply of a
/// lockstep method and every `sync`, so a host that breaks the order is a protocol error and a
/// launcher that does is a programming error.
class RetroLockstepTracker {
  /// The frame the next step is for, or null while the game is not in lockstep.
  int? get nextStep => _next;
  int? _next;

  /// The connected ports of the last step sent: what the game keeps once it leaves lockstep.
  int? get lastPorts => _lastPorts;
  int? _lastPorts;

  /// The newest frame a `sync` came for in the current count.
  int? _lastSync;

  /// The steps sent in the current count, so a `sync` for a frame never stepped is refused.
  int? _first;

  bool get inLockstep => _next != null;

  /// A game started: in lockstep at frame 0 when its `start` had `lockstep`.
  void started({required bool lockstep}) {
    _next = lockstep ? 0 : null;
    _first = _next;
    _lastSync = null;
  }

  /// No game is loaded any more.
  void ended() {
    _next = null;
    _first = null;
    _lastSync = null;
  }

  /// Checks [step] is the next one and counts it.
  void sending(RetroStep step) {
    final next = _next;
    if (next == null) throw StateError('A step was sent while the game is not in lockstep.');
    if (step.frame != next) throw StateError('The step for frame ${step.frame} is not the next, $next.');
    _next = next + 1;
    _lastPorts = step.ports.length;
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
        _restart(frame, keepSyncs: keeps);
        return frame;
      case 'saveState' || 'loadState':
        if (result == false) return null;
        if (result is! Map<String, Object?>) {
          throw RetroProtocolError('The result of $method must be an object or false.');
        }
        final position = RetroStatePosition.parse(result, method);
        if (_next == null) throw RetroProtocolError('$method gave a state for a game not in lockstep.');
        if (method == 'loadState') _restart(position.frame, keepSyncs: false);
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

  /// A `sync`: in frame order, for a frame stepped in the current count.
  RetroSync synced(Map<String, Object?> map) {
    final sync = RetroSync.parse(map);
    final next = _next;
    final first = _first;
    if (next == null || first == null) throw const RetroProtocolError('A sync came for a game not in lockstep.');
    if (sync.frame < first || sync.frame >= next) {
      throw RetroProtocolError('A sync came for frame ${sync.frame}, which was not stepped.');
    }
    final last = _lastSync;
    if (last != null && sync.frame <= last) {
      throw RetroProtocolError('A sync for frame ${sync.frame} came after the one for frame $last.');
    }
    _lastSync = sync.frame;
    return sync;
  }
}

/// What an online match uses of one emulator host: the lockstep methods, its steps and syncs.
/// [RetroHostClient] is the real one.
abstract interface class RetroLockstepHost {
  /// The host's `welcome.hostVersion`: two players' hosts must be the same release.
  String get hostVersion;

  /// Whether the host lists [retroCapabilityPs1Lockstep].
  bool get canLockstep;

  /// Each `sync`, checked and in frame order.
  Stream<RetroSync> get syncs;

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
}
