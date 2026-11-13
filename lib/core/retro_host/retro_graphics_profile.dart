/// One setting the Auto Optimizer changed: the value the game had before, what the player had
/// saved for it before (null when nothing was), and the value it gave.
typedef RetroOptimizedValue = ({String before, String? saved, String applied});

/// One game's graphics as the player keeps them: the picture settings chosen for it, and what the
/// Auto Optimizer changed, for Undo, until the player changes a setting by hand.
class RetroGraphicsProfile {
  RetroGraphicsProfile({Map<String, String>? options, this.optimized}) : options = options ?? {};

  /// Core option values by key, given to the game at `start` over the player's other options.
  final Map<String, String> options;

  /// What the Auto Optimizer changed, by key; null when Undo has nothing to undo.
  Map<String, RetroOptimizedValue>? optimized;

  bool get isEmpty => options.isEmpty && optimized == null;

  Map<String, Object?> toJson() => {
    if (options.isNotEmpty) 'options': options,
    if (optimized case final Map<String, RetroOptimizedValue> changed)
      'optimized': {
        for (final MapEntry(:key, :value) in changed.entries)
          key: {'before': value.before, 'saved': ?value.saved, 'applied': value.applied},
      },
  };

  /// A profile from [json]; whatever is not as [toJson] writes it is left out.
  static RetroGraphicsProfile fromJson(Object? json) {
    if (json is! Map<dynamic, dynamic>) return RetroGraphicsProfile();
    final options = <String, String>{
      if (json['options'] case final Map<dynamic, dynamic> entries)
        for (final MapEntry(:key, :value) in entries.entries)
          if (key is String && value is String) key: value,
    };
    Map<String, RetroOptimizedValue>? optimized;
    if (json['optimized'] case final Map<dynamic, dynamic> entries) {
      optimized = {
        for (final MapEntry(:key, :value) in entries.entries)
          if (value case {'before': final String before, 'applied': final String applied} when key is String)
            key: (before: before, saved: value['saved'] is String ? value['saved'] as String : null, applied: applied),
      };
      if (optimized.isEmpty) optimized = null;
    }
    return RetroGraphicsProfile(options: options, optimized: optimized);
  }
}
