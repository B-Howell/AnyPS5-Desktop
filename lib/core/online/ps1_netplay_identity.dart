enum Ps1NetplayMismatch { version, title, disc, bios, core, profile, card }

/// Compatibility metadata for the reliable PS1 match handshake.
///
/// Disc is a digest of canonical track content and layout. Profile is a digest
/// of the exact deterministic core settings and controller configuration.
/// Card identifies the agreed starting memory card, including a blank card.
final class Ps1NetplayIdentity {
  Ps1NetplayIdentity._(this._fields);

  final Map<String, Object> _fields;

  static final _title = RegExp(r'^[A-Z0-9][A-Z0-9-]{0,31}$');
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  static Ps1NetplayIdentity? tryRead(Object? data) {
    if (data is! Map || data.length != Ps1NetplayMismatch.values.length) return null;
    final version = data['version'];
    final title = data['title'];
    if (version is! int || version < 1 || version > 65535 || title is! String || !_title.hasMatch(title)) {
      return null;
    }
    final fields = <String, Object>{'version': version, 'title': title};
    for (final field in Ps1NetplayMismatch.values.skip(2)) {
      final value = data[field.name];
      if (value is! String || !_digest.hasMatch(value)) return null;
      fields[field.name] = value;
    }
    return Ps1NetplayIdentity._(Map.unmodifiable(fields));
  }

  Map<String, Object> toJson() => _fields;

  Ps1NetplayMismatch? mismatchWith(Ps1NetplayIdentity peer) {
    for (final field in Ps1NetplayMismatch.values) {
      if (_fields[field.name] != peer._fields[field.name]) return field;
    }
    return null;
  }
}
