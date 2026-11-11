import 'retro_button_map.dart';

/// Which button layout an emulated game plays with.
///
/// Every game remembers its own choice, per player: the scope `gameId` for Player 1 and
/// `gameId#p2` and up for the others. A scope holds the name of a saved profile, a layout of its
/// own, or both (the layout stays behind a chosen profile, so Custom can be chosen again). The
/// three collections are the ones the preferences store, so a change here is a change there.
final class RetroControlProfiles {
  const RetroControlProfiles({required this.layouts, required this.saved, required this.chosen});

  static const players = 4;

  /// A scope's own layout.
  final Map<String, RetroButtonMap> layouts;

  /// The saved profiles by name.
  final Map<String, RetroButtonMap> saved;

  /// The saved profile each scope uses.
  final Map<String, String> chosen;

  static String scope(String gameId, int player) => player <= 1 ? gameId : '$gameId#p$player';

  /// The saved profile [scope] uses, or null when it plays with a layout of its own.
  String? profileOf(String scope) {
    final name = chosen[scope];
    return saved.containsKey(name) ? name : null;
  }

  RetroButtonMap layoutOf(String scope) {
    final name = profileOf(scope);
    return name == null ? layouts[scope] ?? RetroButtonMap.standard : saved[name]!;
  }

  RetroButtonMap resolve(String gameId, int player) => layoutOf(scope(gameId, player));

  List<String> get names => saved.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  /// A changed layout: it goes into the saved profile [scope] uses, so every game on that
  /// profile follows, or into the scope's own layout.
  void edit(String scope, RetroButtonMap map) {
    final name = profileOf(scope);
    if (name != null) {
      saved[name] = map;
    } else {
      _store(scope, map);
    }
  }

  /// [scope] set to a layout of its own, leaving any saved profile it used.
  void useLayout(String scope, RetroButtonMap map) {
    chosen.remove(scope);
    _store(scope, map);
  }

  /// [scope] set to a saved profile. Its own layout stays where it is, so an unsaved Custom
  /// layout can be chosen again.
  void useProfile(String scope, String name) {
    if (!saved.containsKey(name)) return;
    chosen[scope] = name;
  }

  /// [scope] back on its own layout, after a saved profile.
  void useOwnLayout(String scope) => chosen.remove(scope);

  /// The first "Profile N" (as [name] words it) that no saved profile has.
  String freeName(String Function(int number) name) {
    for (var number = 1; ; number++) {
      if (!saved.containsKey(name(number))) return name(number);
    }
  }

  /// The layout of [scope] kept as a new profile that [scope] then uses. Returns its name:
  /// [name], or [name] with a number when that one is taken.
  String saveAs(String scope, String name) {
    final unique = _unique(name.trim());
    saved[unique] = layoutOf(scope);
    useProfile(scope, unique);
    layouts.remove(scope);
    return unique;
  }

  /// False when [to] is empty or another profile has it.
  bool rename(String from, String to) {
    final name = to.trim();
    if (name == from) return true;
    if (name.isEmpty || !saved.containsKey(from) || saved.containsKey(name)) return false;
    saved[name] = saved.remove(from)!;
    for (final scope in [...chosen.keys]) {
      if (chosen[scope] == from) chosen[scope] = name;
    }
    return true;
  }

  /// A deleted profile's games go back to their own layout, or to the standard one.
  void delete(String name) {
    saved.remove(name);
    chosen.removeWhere((_, value) => value == name);
  }

  void _store(String scope, RetroButtonMap map) {
    if (map.isStandard) {
      layouts.remove(scope);
    } else {
      layouts[scope] = map;
    }
  }

  String _unique(String name) {
    if (!saved.containsKey(name)) return name;
    for (var number = 2; ; number++) {
      final candidate = '$name $number';
      if (!saved.containsKey(candidate)) return candidate;
    }
  }
}
