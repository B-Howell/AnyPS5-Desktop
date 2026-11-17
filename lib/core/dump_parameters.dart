import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'param_sfo.dart';

/// The console a dump was made for, told by its parameter file: a PS5 dump has
/// sce_sys/param.json, a PS4 dump sce_sys/param.sfo.
enum DumpPlatform {
  ps5('PS5', runs: true),

  /// The engine reads a PS4 dump's param.sfo, but upstream AnyPS5 does not run PS4 executables
  /// yet (boykopovar/AnyPS5#3093): its relinker stops on them before any library code runs, and
  /// the fixes they need are still open. Its games are listed, with what the dump says, and
  /// cannot be unlocked.
  ps4('PS4', runs: false);

  const DumpPlatform(this.label, {required this.runs});

  /// The console's name as the library shows it, the same in every language.
  final String label;

  /// Whether the engine the launcher downloads runs this console's games.
  final bool runs;
}

/// What a dump's parameter file says about it, the same for both consoles: sce_sys/param.json
/// (PS5) or sce_sys/param.sfo (PS4), read in that order, as the engine reads them.
class DumpParameters {
  const DumpParameters({
    required this.platform,
    this.titleId,
    this.version,
    this.title,
    this.names = const {},
    this.defaultLanguage = 'en-US',
    this.contentId,
    this.ageLevel,
  });

  final DumpPlatform platform;

  /// PPSA01234 or CUSA01234.
  final String? titleId;

  /// param.json's contentVersion (01.004.000), param.sfo's APP_VER (01.09).
  final String? version;

  /// The name in the dump's default language.
  final String? title;

  /// Every language's name, by locale tag (en-US, tr-TR...).
  final Map<String, String> names;
  final String defaultLanguage;

  /// UP0000-PPSA01234_00-ABCDEFGHIJKLMNOP: the publisher, title and entitlement label.
  final String? contentId;

  /// param.json's ageLevel as written, null for a PS4 dump, whose PARENTAL_LEVEL is no age.
  final Object? ageLevel;

  static const jsonFile = 'param.json';
  static const sfoFile = 'param.sfo';

  /// The files that can describe a dump, inside its sce_sys, in the order they are read.
  static const files = [jsonFile, sfoFile];

  /// The console language codes of param.sfo's TITLE_00 to TITLE_30 (the system's language
  /// parameter: 0 Japanese, 1 American English...), as locale tags.
  static const sfoLanguages = [
    'ja-JP', 'en-US', 'fr-FR', 'es-ES', 'de-DE', 'it-IT', 'nl-NL', 'pt-PT', 'ru-RU', 'ko-KR', 'zh-Hant', //
    'zh-Hans', 'fi-FI', 'sv-SE', 'da-DK', 'no-NO', 'pl-PL', 'pt-BR', 'en-GB', 'tr-TR', 'es-419', 'ar-AE', //
    'fr-CA', 'cs-CZ', 'hu-HU', 'el-GR', 'ro-RO', 'th-TH', 'vi-VN', 'id-ID', 'uk-UA',
  ];

  /// The parameters of the dump in [folder], null when neither file is there or reads.
  static DumpParameters? read(String folder) {
    for (final name in files) {
      final found = readFile(p.join(folder, 'sce_sys', name));
      if (found != null) return found;
    }
    return null;
  }

  /// The parameter file at [path], by its name; null when it is not there or does not read.
  static DumpParameters? readFile(String path) {
    final name = p.basename(path).toLowerCase();
    if (name == sfoFile) {
      final sfo = ParamSfo.read(path);
      return sfo == null ? null : fromSfo(sfo);
    }
    if (name != jsonFile) return null;
    try {
      return parse(name, File(path).readAsBytesSync());
    } on FileSystemException {
      return null;
    }
  }

  /// The parameter file named [name] (param.json or param.sfo) from [bytes].
  static DumpParameters? parse(String name, List<int> bytes) {
    switch (p.basename(name).toLowerCase()) {
      case sfoFile:
        final sfo = ParamSfo.parse(bytes);
        return sfo == null ? null : fromSfo(sfo);
      case jsonFile:
        try {
          final start = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
          final decoded = jsonDecode(utf8.decode(bytes.sublist(start), allowMalformed: true));
          return decoded is Map<String, dynamic> ? fromJson(decoded) : null;
        } on FormatException {
          return null;
        }
      default:
        return null;
    }
  }

  /// A PS5 dump's param.json: titleId, contentVersion, contentId, ageLevel and the names in
  /// localizedParameters, whose defaultLanguage may also be at the top.
  static DumpParameters fromJson(Map<String, dynamic> json) {
    final localized = json['localizedParameters'] is Map<String, dynamic>
        ? json['localizedParameters'] as Map<String, dynamic>
        : <String, dynamic>{};
    final language = _string(localized['defaultLanguage']) ?? _string(json['defaultLanguage']) ?? 'en-US';
    final names = <String, String>{
      for (final MapEntry(:key, :value) in localized.entries)
        if (value is Map<String, dynamic>) key: ?_string(value['titleName']),
    };
    return DumpParameters(
      platform: DumpPlatform.ps5,
      titleId: _string(json['titleId']),
      version: _string(json['contentVersion']),
      title: names[language] ?? names['en-US'],
      names: names,
      defaultLanguage: language,
      contentId: _string(json['contentId']),
      ageLevel: json['ageLevel'],
    );
  }

  /// A PS4 dump's param.sfo: TITLE_ID, APP_VER, CONTENT_ID, TITLE and each language's TITLE_nn.
  /// The default language is the one whose name is TITLE, else American English. CATEGORY (gd for
  /// a game, gp for its update, ac for an add-on) is not what tells them apart: a game with its
  /// update copied over it keeps the update's gp, and where a dump is says what it is, as for a
  /// PS5 dump.
  static DumpParameters fromSfo(ParamSfo sfo) {
    final texts = sfo.texts;
    final names = <String, String>{
      for (var code = 0; code < sfoLanguages.length; code++)
        sfoLanguages[code]: ?_string(texts['TITLE_${code.toString().padLeft(2, '0')}']),
    };
    final title = _string(texts['TITLE']);
    return DumpParameters(
      platform: DumpPlatform.ps4,
      titleId: _string(texts['TITLE_ID']),
      version: _string(texts['APP_VER']),
      title: title ?? names['en-US'],
      names: names,
      defaultLanguage: names.entries.where((entry) => entry.value == title).firstOrNull?.key ?? 'en-US',
      contentId: _string(texts['CONTENT_ID']),
    );
  }

  static String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;
}
