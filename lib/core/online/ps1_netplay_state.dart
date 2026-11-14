import 'dart:typed_data';

import '../retro_host/retro_lockstep.dart';

/// Whether a state file is fit to go to another player: a SwanStation state the host saved for
/// netplay with its SwanStation patches (anyps5-retro-host docs/netplay.md "Determinism", and
/// docs/host.md "SwanStation patches"). Such a state names no file or folder of the machine that
/// saved it, and carries what the analog-mode button combination and each controller were doing.
/// The launcher checks the host player's state before it sends it, and the friend's launcher
/// before it loads it, so neither a path nor a state that would make the two games differ crosses
/// the network.
abstract final class Ps1NetplayState {
  /// SwanStation's `SAVE_STATE_MAGIC`, "DUCC" in little-endian order.
  static const _stateMagic = 0x43435544;

  /// The state version of the host's patch `swanstation-1-netplay-input-state`: from it on, each
  /// controller saves whether the analog-mode combination is held and whether the game locked the
  /// analog mode.
  static const minimumVersion = 58;

  /// The size of SwanStation's `SAVE_STATE_HEADER`.
  static const _headerBytes = 216;

  /// SwanStation's libretro disc trailer (`DiskStateHeader`) after the machine's data: its magic,
  /// "SWANDISC" in little-endian order, and its size.
  static const _discMagic = 0x435349444e415753;
  static const _discBytes = 24;
  static const _discVersion = 1;

  /// The trailer flag of the patch `swanstation-2-pathless-netplay-state`: the state names its
  /// disc by its place in the disc list, and no path.
  static const _pathless = 8;

  /// The flags a trailer may have: ejected, no disc, a container of several discs, pathless.
  static const _knownFlags = 15;

  /// Why [file] may not go to another player, for a log; null when it may.
  static String? problem(Uint8List file) {
    final state = RetroStateFile.read(file);
    if (state == null) return 'it is not a version ${RetroStateFile.version} state file';
    final core = state.core;
    if (core.length < _headerBytes) return 'its core data is too short';
    final data = ByteData.sublistView(core);
    int word(int offset) => data.getUint32(offset, Endian.little);
    if (word(0) != _stateMagic) return 'it is not a SwanStation state';
    if (word(4) < minimumVersion) return 'its SwanStation state version ${word(4)} is older than $minimumVersion';
    if (core.sublist(8, 136).any((byte) => byte != 0)) return 'it names the game\'s title';
    if (word(168) != 0) return 'it names the disc\'s file';
    if (word(200) != 0) return 'its machine data is compressed';
    final end = word(212) + word(208);
    if (word(212) < _headerBytes || end + _discBytes > core.length) return 'it has no disc trailer';
    if (data.getUint64(end, Endian.little) != _discMagic || word(end + 8) != _discVersion) {
      return 'it has no disc trailer';
    }
    final flags = word(end + 12);
    if (flags & ~_knownFlags != 0 || flags & _pathless == 0) return 'its disc trailer is not pathless';
    if (word(end + 20) != 0) return 'its disc trailer names a path';
    return null;
  }
}
