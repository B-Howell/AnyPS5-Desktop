/// The values and message rules of the emulator host's protocol, version 1 (anyps5-retro-host
/// docs/protocol.md), as the launcher's client checks them.
library;

/// The other side broke a rule that protocol.md "Protocol errors" lists. The launcher kills the
/// host and handles it as a host failure.
class RetroProtocolError implements Exception {
  const RetroProtocolError(this.message);

  final String message;

  @override
  String toString() => 'RetroProtocolError: $message';
}

/// A call's `error` reply (protocol.md "call and reply"). [code] is what programs act on; a code
/// this launcher does not know is a failure without a known cause.
class RetroCallError implements Exception {
  const RetroCallError(this.code, this.message);

  final String code;
  final String message;

  static const unknownMethod = 'unknownMethod';
  static const argument = 'argument';
  static const busy = 'busy';
  static const start = 'start';
  static const tooLarge = 'tooLarge';

  @override
  String toString() => 'RetroCallError($code): $message';
}

/// The two frame pixel formats version 1 defines, and their codes in the ring header.
abstract final class RetroPixelFormat {
  static const rgba8 = 'rgba8';
  static const bgra8 = 'bgra8';

  static int code(String format) => format == rgba8 ? 1 : 2;
}

/// The protocol version this launcher speaks.
const retroProtocolVersion = 1;

/// The capability every method of version 1 needs.
const retroCapabilityPs1 = 'ps1';

/// The capability that adds `core` to `status`: the loaded core's name and build identity
/// (protocol.md "status").
const retroCapabilityCoreIdentity = 'coreIdentity';

/// The capability that adds `timing` to `status`: the frame rate the host paces the game to and the
/// game's region (protocol.md "status").
const retroCapabilityGameTiming = 'gameTiming';

/// The `errorCode` values a `status` can carry, and the two the client reports itself after a host
/// failure (protocol.md "Host failure").
abstract final class RetroErrorCode {
  static const none = '';
  static const bios = 'bios';
  static const disc = 'disc';
  static const core = 'core';
  static const stalled = 'stalled';
  static const didNotStart = 'didNotStart';
  static const frameTooLarge = 'frameTooLarge';
  static const other = 'other';
  static const hostExited = 'hostExited';
  static const hostHung = 'hostHung';
}

/// Reads fields of a received message, throwing [RetroProtocolError] when one is missing, has the
/// wrong type, or is out of its range.
class RetroFields {
  const RetroFields(this.map, this.where);

  final Map<String, Object?> map;
  final String where;

  static const maxId = 2147483647;
  static const maxUint32 = 4294967295;

  Never _bad(String key, String rule) => throw RetroProtocolError('$where.$key $rule.');

  bool has(String key) => map.containsKey(key);

  int integer(String key, int min, int max) {
    final value = map[key];
    if (value is! int) _bad(key, 'must be an integer');
    if (value < min || value > max) _bad(key, 'must be from $min to $max');
    return value;
  }

  double number(String key, {double? above, double? atMost}) {
    final value = map[key];
    if (value is! num) _bad(key, 'must be a number');
    final number = value.toDouble();
    if (above != null && !(number > above)) _bad(key, 'must be greater than $above');
    if (atMost != null && number > atMost) _bad(key, 'must be at most $atMost');
    return number;
  }

  String string(String key) {
    final value = map[key];
    if (value is! String) _bad(key, 'must be a string');
    return value;
  }

  String? stringOrNull(String key) {
    if (!map.containsKey(key)) _bad(key, 'is missing');
    final value = map[key];
    if (value != null && value is! String) _bad(key, 'must be a string or null');
    return value as String?;
  }

  bool boolean(String key) {
    final value = map[key];
    if (value is! bool) _bad(key, 'must be a boolean');
    return value;
  }

  List<String> strings(String key) {
    final value = map[key];
    if (value is! List<Object?> || value.any((item) => item is! String)) _bad(key, 'must be an array of strings');
    return value.cast<String>();
  }

  RetroFields object(String key) {
    final value = map[key];
    if (value is! Map<String, Object?>) _bad(key, 'must be an object');
    return RetroFields(value, '$where.$key');
  }
}

/// One core option a `status` lists (protocol.md "status").
class RetroOption {
  const RetroOption({
    required this.key,
    required this.title,
    required this.values,
    required this.labels,
    required this.selected,
    required this.activeValue,
    required this.restart,
  });

  final String key;
  final String title;
  final List<String> values;
  final List<String> labels;
  final int selected;
  final String activeValue;
  final bool restart;

  Map<String, Object?> toJson() => {
    'title': title,
    'values': values,
    'labels': labels,
    'selected': selected,
    'activeValue': activeValue,
    'restart': restart,
  };
}

/// The discs of a multi-disc game.
class RetroDiscs {
  const RetroDiscs({
    required this.labels,
    required this.inserted,
    required this.insertedDiscPath,
    required this.playedDiscPath,
    required this.busy,
    required this.failed,
  });

  final List<String> labels;
  final int? inserted;
  final String? insertedDiscPath;
  final String playedDiscPath;
  final bool busy;
  final bool failed;

  Map<String, Object?> toJson() => {
    'labels': labels,
    'inserted': inserted,
    'insertedDiscPath': insertedDiscPath,
    'playedDiscPath': playedDiscPath,
    'busy': busy,
    'failed': failed,
  };
}

/// The core a game loaded, as `status.core` gives it (capability [retroCapabilityCoreIdentity]): the
/// `library_name` and `library_version` the core reports, each `""` when the host could not pass
/// it on as printable ASCII of at most 256 bytes.
class RetroCore {
  const RetroCore({required this.name, required this.version});

  final String name;
  final String version;

  /// The longest name or version a host sends.
  static const maxBytes = 256;

  static final _printable = RegExp(r'^[ -~]*$');

  /// The form of the core build identity the host's own SwanStation builds report: `anyps5-1-`
  /// and the SHA-256 of the build's source manifest (anyps5-retro-host docs/netplay.md "Core build
  /// identity").
  static final _identity = RegExp(r'^anyps5-1-[0-9a-f]{64}$');

  /// Whether [version] is a core build identity, so the core can be compared with a friend's.
  bool get identified => _identity.hasMatch(version);

  /// Whether a match may be played between this core and [theirs]: both identified and the same,
  /// as protocol.md "status" asks. Anything else is a different core.
  bool playsWith(RetroCore theirs) => identified && name == theirs.name && version == theirs.version;

  /// Whether [value] is a name or version a host may send.
  static bool valid(String value) => value.length <= maxBytes && _printable.hasMatch(value);

  Map<String, Object?> toJson() => {'name': name, 'version': version};

  @override
  bool operator ==(Object other) => other is RetroCore && other.name == name && other.version == version;

  @override
  int get hashCode => Object.hash(name, version);

  @override
  String toString() => '$name $version';
}

/// A game's frame rate and region, as `status.timing` gives them (capability
/// [retroCapabilityGameTiming]). Both come from the emulated console, so two players' hosts running
/// the same disc on the same core build give the same values at the same frame.
class RetroTiming {
  const RetroTiming({required this.fps, this.region = ''});

  /// The frames a second the host runs the game at when it keeps its own time: the vertical
  /// frequency of the video mode the game set, about 60 for NTSC and 50 for PAL.
  final double fps;

  /// `ntsc`, `pal`, or `""` for a region the core names otherwise.
  final String region;

  static const regions = {'ntsc', 'pal', ''};

  /// How long one frame lasts at [fps].
  Duration get frame => Duration(microseconds: (Duration.microsecondsPerSecond / fps).round());

  Map<String, Object?> toJson() => {'fps': fps, 'region': region};

  @override
  bool operator ==(Object other) => other is RetroTiming && other.fps == fps && other.region == region;

  @override
  int get hashCode => Object.hash(fps, region);

  @override
  String toString() => '$fps fps, $region';
}

/// A loaded game's state, from `status`, or the shorter form the client gives after a host failure.
class RetroStatus {
  const RetroStatus({
    required this.ready,
    required this.ended,
    required this.error,
    required this.errorCode,
    this.aspect = 4 / 3,
    this.hardware = false,
    this.resolutionError = '',
    this.graphicsPending = false,
    this.progressLabel,
    this.progressPercent,
    this.options = const {},
    this.discs,
    this.core,
    this.timing,
  });

  /// What the client reports from a host failure until the UI calls `release`.
  const RetroStatus.failed({required this.error, required this.errorCode})
    : ready = false,
      ended = true,
      aspect = 4 / 3,
      hardware = false,
      resolutionError = '',
      graphicsPending = false,
      progressLabel = null,
      progressPercent = null,
      options = const {},
      discs = null,
      core = null,
      timing = null;

  final bool ready;
  final bool ended;
  final String error;
  final String errorCode;
  final double aspect;
  final bool hardware;
  final String resolutionError;
  final bool graphicsPending;
  final String? progressLabel;
  final int? progressPercent;
  final Map<String, RetroOption> options;
  final RetroDiscs? discs;

  /// The core the game loaded; null until it is loaded, when it could not be, and from a host
  /// without [retroCapabilityCoreIdentity].
  final RetroCore? core;

  /// The game's frame rate and region; null until the core has loaded the game, when it did not,
  /// and from a host without [retroCapabilityGameTiming].
  final RetroTiming? timing;

  /// The status as protocol.md "status" writes it.
  Map<String, Object?> toJson() => {
    ...toFailureJson(),
    'aspect': aspect,
    'hardware': hardware,
    'resolutionError': resolutionError,
    'graphicsPending': graphicsPending,
    'progressLabel': progressLabel,
    'progressPercent': progressPercent,
    'options': {for (final option in options.values) option.key: option.toJson()},
    'discs': ?discs?.toJson(),
    'core': ?core?.toJson(),
    'timing': ?timing?.toJson(),
  };

  /// The four fields protocol.md "Host failure" gives for a status the client made.
  Map<String, Object?> toFailureJson() => {'ready': ready, 'ended': ended, 'error': error, 'errorCode': errorCode};

  /// Whether [map] is the client's own failure report rather than a host's status, which always
  /// has every field.
  static bool isFailureReport(Map<String, Object?> map) =>
      map.length == 4 && (map['errorCode'] == RetroErrorCode.hostExited || map['errorCode'] == RetroErrorCode.hostHung);

  /// Reads a `status` result, throwing [RetroProtocolError] for a field out of what protocol.md
  /// allows. Unknown fields are ignored. A host that lists [retroCapabilityCoreIdentity]
  /// ([coreIdentity]) always sends `core`, an object or null; any other host's `core` is ignored.
  /// The same holds for `timing` and [retroCapabilityGameTiming] ([gameTiming]).
  static RetroStatus parse(Map<String, Object?> map, {bool coreIdentity = false, bool gameTiming = false}) {
    final f = RetroFields(map, 'status');
    final options = <String, RetroOption>{};
    final optionFields = f.object('options');
    for (final key in optionFields.map.keys) {
      final o = optionFields.object(key);
      final values = o.strings('values');
      final labels = o.strings('labels');
      if (labels.length != values.length) throw RetroProtocolError('status.options.$key.labels must match values.');
      options[key] = RetroOption(
        key: key,
        title: o.string('title'),
        values: values,
        labels: labels,
        selected: values.isEmpty
            ? throw RetroProtocolError('status.options.$key.values is empty.')
            : o.integer('selected', 0, values.length - 1),
        activeValue: o.string('activeValue'),
        restart: o.boolean('restart'),
      );
    }
    RetroDiscs? discs;
    if (f.has('discs')) {
      final d = f.object('discs');
      final labels = d.strings('labels');
      if (!d.has('inserted')) throw const RetroProtocolError('status.discs.inserted is missing.');
      final inserted = d.map['inserted'];
      if (inserted != null && (inserted is! int || inserted < 0 || inserted >= labels.length)) {
        throw const RetroProtocolError('status.discs.inserted must be a disc index or null.');
      }
      discs = RetroDiscs(
        labels: labels,
        inserted: inserted as int?,
        insertedDiscPath: d.stringOrNull('insertedDiscPath'),
        playedDiscPath: d.string('playedDiscPath'),
        busy: d.boolean('busy'),
        failed: d.boolean('failed'),
      );
    }
    if (!f.has('progressPercent')) throw const RetroProtocolError('status.progressPercent is missing.');
    final percent = map['progressPercent'];
    if (percent != null && (percent is! int || percent < 0 || percent > 100)) {
      throw const RetroProtocolError('status.progressPercent must be an integer from 0 to 100 or null.');
    }
    return RetroStatus(
      ready: f.boolean('ready'),
      ended: f.boolean('ended'),
      error: f.string('error'),
      errorCode: f.string('errorCode'),
      aspect: f.number('aspect', above: 0, atMost: 10),
      hardware: f.boolean('hardware'),
      resolutionError: f.string('resolutionError'),
      graphicsPending: f.boolean('graphicsPending'),
      progressLabel: f.stringOrNull('progressLabel'),
      progressPercent: percent as int?,
      options: options,
      discs: discs,
      core: coreIdentity ? _core(f) : null,
      timing: gameTiming ? _timing(f) : null,
    );
  }

  static RetroTiming? _timing(RetroFields f) {
    if (!f.has('timing')) throw const RetroProtocolError('status.timing is missing.');
    if (f.map['timing'] == null) return null;
    final t = f.object('timing');
    final fps = t.number('fps', above: 1);
    if (fps >= 1000) throw const RetroProtocolError('status.timing.fps must be below 1000.');
    final region = t.string('region');
    if (!RetroTiming.regions.contains(region)) throw RetroProtocolError('status.timing.region $region is unknown.');
    return RetroTiming(fps: fps, region: region);
  }

  static RetroCore? _core(RetroFields f) {
    if (!f.has('core')) throw const RetroProtocolError('status.core is missing.');
    if (f.map['core'] == null) return null;
    final c = f.object('core');
    final name = c.string('name');
    final version = c.string('version');
    if (!RetroCore.valid(name) || !RetroCore.valid(version)) {
      throw const RetroProtocolError('status.core must be printable ASCII of at most 256 bytes.');
    }
    return RetroCore(name: name, version: version);
  }
}
