import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/online/ps1_file_digests.dart';
import 'package:anyps5_desktop/core/online/ps1_lockstep_media.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What two launchers compare a disc by (lib/core/online/ps1_lockstep_media.dart): its tracks in the
/// disc list's order, whatever the files are called, and the digests kept so a disc is read once
/// (lib/core/online/ps1_file_digests.dart).
void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('lockstep-media-'));
  tearDown(() => folder.deleteSync(recursive: true));

  File write(String name, List<int> bytes) => File(p.join(folder.path, name))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  /// A data disc's cue sheet naming [tracks], as the library reads one.
  List<int> cue(List<String> tracks) => utf8.encode(
    [
      for (final (index, track) in tracks.indexed) ...[
        'FILE "$track" BINARY',
        '  TRACK ${(index + 1).toString().padLeft(2, '0')} ${index == 0 ? 'MODE2/2352' : 'AUDIO'}',
        '    INDEX 01 00:00:00',
      ],
    ].join('\n'),
  );

  test('a disc is its tracks: neither its folder, nor its file names, nor its sheet count', () async {
    final digests = Ps1FileDigests(p.join(folder.path, 'digests.json'));
    write(p.join('mine', 'Night Racer.cue'), cue(['Night Racer (Track 1).bin', 'Night Racer (Track 2).bin']));
    write(p.join('mine', 'Night Racer (Track 1).bin'), List.filled(4096, 7));
    write(p.join('mine', 'Night Racer (Track 2).bin'), List.filled(2352, 9));
    write(p.join('theirs', 'my copy.cue'), cue(['data.bin', 'music.bin']));
    write(p.join('theirs', 'data.bin'), List.filled(4096, 7));
    write(p.join('theirs', 'music.bin'), List.filled(2352, 9));
    final mine = GameLibrary.discFiles(p.join(folder.path, 'mine', 'Night Racer.cue'));
    final theirs = GameLibrary.discFiles(p.join(folder.path, 'theirs', 'my copy.cue'));
    expect(mine.map(p.basename), ['Night Racer.cue', 'Night Racer (Track 1).bin', 'Night Racer (Track 2).bin']);
    expect(await Ps1LockstepMedia.discDigest(digests, mine), await Ps1LockstepMedia.discDigest(digests, theirs));
    expect(Ps1LockstepMedia.discBytes(mine), 4096 + 2352, reason: 'the sheet is not counted');
    expect(Ps1LockstepMedia.couldBe(theirs, 4096 + 2352), isTrue);
    expect(Ps1LockstepMedia.couldBe([p.join(folder.path, 'theirs', 'gone.bin')], 4096 + 2352), isFalse);

    write(p.join('theirs', 'music.bin'), List.filled(2352, 8));
    expect(
      await Ps1LockstepMedia.discDigest(digests, theirs),
      isNot(await Ps1LockstepMedia.discDigest(digests, mine)),
      reason: 'another track is another disc',
    );
  });

  test("a playlist's discs count in its order, which the state names a disc by", () async {
    final digests = Ps1FileDigests(p.join(folder.path, 'digests.json'));
    write('Disc 1.cue', cue(['Disc 1.bin']));
    write('Disc 1.bin', List.filled(4096, 1));
    write('Disc 2.cue', cue(['Disc 2.bin']));
    write('Disc 2.bin', List.filled(4096, 2));
    write('game.m3u', utf8.encode('Disc 1.cue\nDisc 2.cue\n'));
    write('swapped.m3u', utf8.encode('Disc 2.cue\nDisc 1.cue\n'));
    final files = GameLibrary.discFiles(p.join(folder.path, 'game.m3u'));
    expect(files.map(p.basename), ['game.m3u', 'Disc 1.cue', 'Disc 1.bin', 'Disc 2.cue', 'Disc 2.bin']);
    expect(Ps1LockstepMedia.tracks(files).map(p.basename), ['Disc 1.bin', 'Disc 2.bin']);
    expect(
      await Ps1LockstepMedia.discDigest(digests, files),
      isNot(await Ps1LockstepMedia.discDigest(digests, GameLibrary.discFiles(p.join(folder.path, 'swapped.m3u')))),
    );
  });

  test("a disc's layout and the discs' boundaries count, though its tracks' contents are the same", () async {
    final digests = Ps1FileDigests(p.join(folder.path, 'digests.json'));
    write('a.bin', List.filled(2352, 1));
    write('b.bin', List.filled(2352, 2));
    write('both.cue', cue(['a.bin', 'b.bin']));
    write('one a.cue', cue(['a.bin']));
    write('one b.cue', cue(['b.bin']));
    write('two discs.m3u', utf8.encode('one a.cue\none b.cue\n'));
    final both = GameLibrary.discFiles(p.join(folder.path, 'both.cue'));
    final two = GameLibrary.discFiles(p.join(folder.path, 'two discs.m3u'));
    expect(Ps1LockstepMedia.discBytes(both), Ps1LockstepMedia.discBytes(two));
    expect(
      await Ps1LockstepMedia.discDigest(digests, both),
      isNot(await Ps1LockstepMedia.discDigest(digests, two)),
      reason: 'one two-track disc is not two one-track discs',
    );

    write('gap.cue', [
      ...cue(['a.bin', 'b.bin']),
      ...utf8.encode('\n    INDEX 00 00:00:00\nREM a comment\n'),
    ]);
    write('remark.cue', [
      ...cue(['a.bin', 'b.bin']),
      ...utf8.encode('\nREM COMMENT "another rip"\n'),
    ]);
    expect(
      await Ps1LockstepMedia.discDigest(digests, GameLibrary.discFiles(p.join(folder.path, 'gap.cue'))),
      isNot(await Ps1LockstepMedia.discDigest(digests, both)),
      reason: 'another index is another layout',
    );
    expect(
      await Ps1LockstepMedia.discDigest(digests, GameLibrary.discFiles(p.join(folder.path, 'remark.cue'))),
      await Ps1LockstepMedia.discDigest(digests, both),
      reason: 'a remark is not part of the layout',
    );
  });

  test('a track named with two spaces, and a remark that is not UTF-8, are read as the library reads them', () async {
    final digests = Ps1FileDigests(p.join(folder.path, 'digests.json'));
    write('Track  01.bin', List.filled(2352, 3));
    write('spaced.cue', [
      ...utf8.encode('REM '),
      0xE9,
      0xFF,
      ...utf8.encode('\n'),
      ...cue(['Track  01.bin']),
    ]);
    write('plain.bin', List.filled(2352, 3));
    write('plain.cue', cue(['plain.bin']));
    final spaced = GameLibrary.discFiles(p.join(folder.path, 'spaced.cue'));
    expect(spaced.map(p.basename), ['spaced.cue', 'Track  01.bin']);
    final digest = await Ps1LockstepMedia.discDigest(digests, spaced);
    expect(digest, await Ps1LockstepMedia.discDigest(digests, GameLibrary.discFiles(p.join(folder.path, 'plain.cue'))));
    expect(Ps1LockstepMedia.knownDisc(digests, spaced), digest);
  });

  test("a playlist's discs in folders of their own have their tracks beside their sheets", () async {
    final digests = Ps1FileDigests(p.join(folder.path, 'digests.json'));
    write(p.join('Disc 1', 'game.cue'), cue(['track.bin']));
    write(p.join('Disc 1', 'track.bin'), List.filled(4096, 1));
    write('track.bin', List.filled(4096, 9));
    write('game.m3u', utf8.encode('Disc 1/game.cue\n'));
    final files = GameLibrary.discFiles(p.join(folder.path, 'game.m3u'));
    expect(files, [
      p.join(folder.path, 'game.m3u'),
      p.join(folder.path, 'Disc 1', 'game.cue'),
      p.join(folder.path, 'Disc 1', 'track.bin'),
    ]);
    expect(await Ps1LockstepMedia.discDigest(digests, files), isNotEmpty);

    File(p.join(folder.path, 'Disc 1', 'track.bin')).deleteSync();
    final incomplete = GameLibrary.discFiles(p.join(folder.path, 'game.m3u'));
    expect(incomplete.map(p.basename), [
      'game.m3u',
      'game.cue',
    ], reason: 'a missing track is left out, not taken from elsewhere');
    expect(
      () => Ps1LockstepMedia.discDigestOf(incomplete, const {}),
      throwsA(isA<FileSystemException>()),
      reason: 'a disc that is not whole has no digest',
    );
  });

  test('a file is read once while it is unchanged, and again once it changes', () async {
    final store = p.join(folder.path, 'kept', 'digests.json');
    final track = write('track.bin', List.filled(8192, 3));
    final when = DateTime(2026, 1, 2, 3, 4, 5);
    track.setLastModifiedSync(when);
    final digests = Ps1FileDigests(store);
    expect(digests.knownNow([track.path]), isNull, reason: 'nothing is known before it was read');
    final first = (await digests.of([track.path]))[track.path];
    expect(first, Ps1FileDigests.fileDigest(track.path));

    track.writeAsBytesSync(List.filled(8192, 4));
    track.setLastModifiedSync(when);
    expect((await digests.of([track.path]))[track.path], first, reason: 'the same size and time are not read again');
    expect(Ps1FileDigests(store).knownNow([track.path]), {
      track.path: first,
    }, reason: 'what was read is kept for the next run');

    track.setLastModifiedSync(when.add(const Duration(seconds: 1)));
    expect(digests.knownNow([track.path]), isNull);
    expect((await digests.of([track.path]))[track.path], Ps1FileDigests.fileDigest(track.path));
    expect((await digests.of([track.path]))[track.path], isNot(first));
  });

  test('a damaged store is read as empty, and a file that is not one is refused', () async {
    final store = write('digests.json', utf8.encode('{"version":1,"files":{"x":{"bytes":"no"}}}')).path;
    final track = write('track.bin', List.filled(16, 1));
    final digests = Ps1FileDigests(store);
    expect(digests.knownNow([track.path]), isNull);
    expect((await digests.of([track.path]))[track.path], Ps1FileDigests.fileDigest(track.path));
    expect(() => digests.of([folder.path]), throwsA(isA<FileSystemException>()));
  });

  test('BIOS images are the 512 KiB files of the system folder, in any order', () async {
    final system = Directory(p.join(folder.path, 'system'))..createSync();
    final none = Ps1LockstepMedia.biosDigestOf(const []);
    File(p.join(system.path, 'readme.txt')).writeAsStringSync('not a BIOS');
    expect(Ps1LockstepMedia.biosImages(system.path), isEmpty);
    File(p.join(system.path, 'b.bin')).writeAsBytesSync(List.filled(Ps1LockstepMedia.biosBytes, 1));
    File(p.join(system.path, 'a.bin')).writeAsBytesSync(List.filled(Ps1LockstepMedia.biosBytes, 2));
    final core = write('core.dll', List.filled(64, 5));
    final identity = await Ps1LockstepMedia.identify(
      digests: Ps1FileDigests(p.join(folder.path, 'digests.json')),
      hostVersion: '1.0.0',
      core: core.path,
      files: [write('game.chd', List.filled(1024, 6)).path],
      system: system.path,
    );
    expect(identity.bios, isNot(none));
    expect(
      identity.bios,
      Ps1LockstepMedia.biosDigestOf([
        for (final image in Ps1LockstepMedia.biosImages(system.path).reversed) Ps1FileDigests.fileDigest(image),
      ]),
    );
    expect(identity.core, Ps1FileDigests.fileDigest(core.path));
    expect(identity.system, Platform.operatingSystem);
  });
}
