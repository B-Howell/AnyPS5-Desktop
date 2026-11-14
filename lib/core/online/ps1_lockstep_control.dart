import 'dart:convert';
import 'dart:typed_data';

/// The reliable, ordered messages two launchers exchange about one PS1 lockstep match
/// (anyps5-retro-host docs/netplay.md "Joining a running game"), as JSON on the peer connection's
/// stream channel. Every message has `v` (the version, 1) and `type`; a message of another version
/// or shape is refused, and the match ends.
sealed class Ps1LockstepMessage {
  const Ps1LockstepMessage();

  static const version = 1;

  /// The largest message read: a state chunk of [Ps1LockstepChunk.maxBytes] in base64 with room
  /// for the rest.
  static const maxBytes = 96 * 1024;

  String get type;

  Map<String, Object?> body();

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({'v': version, 'type': type, ...body()})));

  /// Reads one message; throws [FormatException] for anything that is not a message of this
  /// version with exactly its fields.
  static Ps1LockstepMessage decode(Uint8List bytes) {
    if (bytes.length > maxBytes) throw const FormatException('A lockstep message is too large.');
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const FormatException('A lockstep message is not JSON.');
    }
    if (json is! Map<String, Object?>) throw const FormatException('A lockstep message is not an object.');
    final fields = _Fields(json);
    if (fields.integer('v', 1, 1) != version) throw const FormatException('A lockstep message has another version.');
    final type = fields.string('type');
    final message = switch (type) {
      'hello' => Ps1LockstepHello._read(fields),
      'ping' => Ps1LockstepPing(fields.integer('id', 0, _maxId)),
      'pong' => Ps1LockstepPong(fields.integer('id', 0, _maxId)),
      'start' => Ps1LockstepStart._read(fields),
      'chunk' => Ps1LockstepChunk._read(fields),
      'loaded' => Ps1LockstepLoaded(fields.integer('frame', 0, _maxFrame)),
      'hash' => Ps1LockstepHash(fields.integer('frame', 0, _maxFrame), fields.hash('ram', 16)),
      'pause' => Ps1LockstepPause(paused: fields.boolean('paused')),
      'leave' => const Ps1LockstepLeave(),
      _ => throw FormatException('A lockstep message has an unknown type, $type.'),
    };
    fields.done();
    return message;
  }

  static const _maxId = 0x7fffffff;
  static const _maxFrame = 0xffffffff;
}

/// What each launcher says first: what it plays the match with. The two must match (netplay.md
/// "Joining a running game", step 1); the host player's [options] are the ones the friend's game
/// starts with.
final class Ps1LockstepHello extends Ps1LockstepMessage {
  const Ps1LockstepHello({
    required this.hostVersion,
    required this.system,
    required this.core,
    required this.disc,
    required this.discName,
    required this.bios,
    required this.options,
  });

  /// The emulator host's `welcome.hostVersion`.
  final String hostVersion;

  /// The launcher's system, as Dart names it (`windows`, `linux`, `macos`): the SwanStation
  /// libraries of two systems are different files.
  final String system;

  /// SHA-256 of the SwanStation library, 64 lowercase hexadecimal digits.
  final String core;

  /// SHA-256 of the disc's files ([Ps1LockstepIdentity]).
  final String disc;

  /// The disc's file name, which SwanStation finds a loaded state's disc by.
  final String discName;

  /// SHA-256 of the BIOS images in the system folder.
  final String bios;

  /// The core options the game runs with, by key.
  final Map<String, String> options;

  @override
  String get type => 'hello';

  @override
  Map<String, Object?> body() => {
    'hostVersion': hostVersion,
    'system': system,
    'core': core,
    'disc': disc,
    'discName': discName,
    'bios': bios,
    'options': options,
  };

  static Ps1LockstepHello _read(_Fields fields) => Ps1LockstepHello(
    hostVersion: fields.string('hostVersion', max: 64),
    system: fields.string('system', max: 16),
    core: fields.hash('core', 64),
    disc: fields.hash('disc', 64),
    discName: fields.string('discName', max: 255),
    bios: fields.hash('bios', 64),
    options: fields.options('options'),
  );
}

final class Ps1LockstepPing extends Ps1LockstepMessage {
  const Ps1LockstepPing(this.id);

  final int id;

  @override
  String get type => 'ping';

  @override
  Map<String, Object?> body() => {'id': id};
}

final class Ps1LockstepPong extends Ps1LockstepMessage {
  const Ps1LockstepPong(this.id);

  final int id;

  @override
  String get type => 'pong';

  @override
  Map<String, Object?> body() => {'id': id};
}

/// The host player's game is held at [frame] and its state follows in [chunks] chunks of the
/// gzip-compressed state file, whose uncompressed [bytes] have the SHA-256 [sha256]. [delay] is the
/// match's input delay in frames and [epoch] names its input packets.
final class Ps1LockstepStart extends Ps1LockstepMessage {
  const Ps1LockstepStart({
    required this.frame,
    required this.delay,
    required this.epoch,
    required this.bytes,
    required this.sha256,
    required this.chunks,
  });

  final int frame;
  final int delay;
  final int epoch;
  final int bytes;
  final String sha256;
  final int chunks;

  static const maxStateBytes = 64 * 1024 * 1024;

  @override
  String get type => 'start';

  @override
  Map<String, Object?> body() => {
    'frame': frame,
    'delay': delay,
    'epoch': BigInt.from(epoch).toUnsigned(64).toRadixString(16).padLeft(16, '0'),
    'bytes': bytes,
    'sha256': sha256,
    'chunks': chunks,
  };

  static Ps1LockstepStart _read(_Fields fields) {
    final epoch = fields.hash('epoch', 16);
    final value = BigInt.parse(epoch, radix: 16).toSigned(64).toInt();
    if (value == 0) throw const FormatException('A lockstep start has epoch 0.');
    return Ps1LockstepStart(
      frame: fields.integer('frame', 0, Ps1LockstepMessage._maxFrame),
      delay: fields.integer('delay', 1, 8),
      epoch: value,
      bytes: fields.integer('bytes', 48, maxStateBytes),
      sha256: fields.hash('sha256', 64),
      chunks: fields.integer('chunks', 1, maxStateBytes ~/ Ps1LockstepChunk.maxBytes + 1),
    );
  }
}

/// One piece of the compressed state, in order from 0.
final class Ps1LockstepChunk extends Ps1LockstepMessage {
  Ps1LockstepChunk(this.index, Uint8List data) : data = Uint8List.fromList(data) {
    if (data.isEmpty || data.length > maxBytes) throw RangeError.range(data.length, 1, maxBytes, 'data');
  }

  static const maxBytes = 64 * 1024;

  final int index;
  final Uint8List data;

  @override
  String get type => 'chunk';

  @override
  Map<String, Object?> body() => {'index': index, 'data': base64.encode(data)};

  static Ps1LockstepChunk _read(_Fields fields) {
    final index = fields.integer('index', 0, Ps1LockstepStart.maxStateBytes ~/ maxBytes);
    final Uint8List data;
    try {
      data = base64.decode(fields.string('data', max: maxBytes * 4 ~/ 3 + 4));
    } on FormatException {
      throw const FormatException('A lockstep chunk is not base64.');
    }
    if (data.isEmpty || data.length > maxBytes) throw const FormatException('A lockstep chunk has a wrong size.');
    return Ps1LockstepChunk(index, data);
  }
}

/// The friend's game loaded the state and continues from [frame].
final class Ps1LockstepLoaded extends Ps1LockstepMessage {
  const Ps1LockstepLoaded(this.frame);

  final int frame;

  @override
  String get type => 'loaded';

  @override
  Map<String, Object?> body() => {'frame': frame};
}

/// The main RAM hash ([RetroSync.ram]) a launcher's host gave after [frame].
final class Ps1LockstepHash extends Ps1LockstepMessage {
  const Ps1LockstepHash(this.frame, this.ram);

  final int frame;
  final String ram;

  @override
  String get type => 'hash';

  @override
  Map<String, Object?> body() => {'frame': frame, 'ram': ram};
}

/// The other player paused (their PS menu is open) or went on.
final class Ps1LockstepPause extends Ps1LockstepMessage {
  const Ps1LockstepPause({required this.paused});

  final bool paused;

  @override
  String get type => 'pause';

  @override
  Map<String, Object?> body() => {'paused': paused};
}

/// The other player left the match.
final class Ps1LockstepLeave extends Ps1LockstepMessage {
  const Ps1LockstepLeave();

  @override
  String get type => 'leave';

  @override
  Map<String, Object?> body() => const {};
}

class _Fields {
  _Fields(this.map);

  final Map<String, Object?> map;
  final _read = <String>{'v', 'type'};

  Never _bad(String key, String rule) => throw FormatException('A lockstep message\'s $key $rule.');

  Object? _take(String key) {
    if (!map.containsKey(key)) _bad(key, 'is missing');
    _read.add(key);
    return map[key];
  }

  int integer(String key, int min, int max) {
    final value = _take(key);
    if (value is! int || value < min || value > max) _bad(key, 'must be an integer from $min to $max');
    return value;
  }

  bool boolean(String key) {
    final value = _take(key);
    if (value is! bool) _bad(key, 'must be a boolean');
    return value;
  }

  String string(String key, {int max = 1 << 20}) {
    final value = _take(key);
    if (value is! String || value.isEmpty || value.length > max || value.contains('\u0000')) {
      _bad(key, 'must be a string of 1 to $max characters');
    }
    return value;
  }

  String hash(String key, int digits) {
    final value = string(key, max: digits);
    if (!RegExp('^[0-9a-f]{$digits}\$').hasMatch(value)) _bad(key, 'must be $digits lowercase hexadecimal digits');
    return value;
  }

  Map<String, String> options(String key) {
    final value = _take(key);
    if (value is! Map<String, Object?> || value.length > 256) _bad(key, 'must be an object of at most 256 strings');
    final options = <String, String>{};
    for (final MapEntry(key: name, :value) in value.entries) {
      if (name.isEmpty || name.length > 128 || value is! String || value.length > 256) {
        _bad(key, 'must hold short strings');
      }
      options[name] = value;
    }
    return Map.unmodifiable(options);
  }

  void done() {
    final unknown = map.keys.where((key) => !_read.contains(key));
    if (unknown.isNotEmpty) throw FormatException('A lockstep message has unknown fields: ${unknown.join(', ')}.');
  }
}
