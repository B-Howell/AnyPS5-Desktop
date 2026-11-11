import 'dart:io';
import 'dart:typed_data';

import 'binary.dart';

/// Inspects a Linux core without loading or executing it. Package hashes still
/// establish provenance; this check establishes the host ABI and required hook.
abstract final class ElfCoreLibrary {
  static bool isX64(File file, {String? requiredExport}) {
    RandomAccessFile? source;
    try {
      source = file.openSync();
      final length = source.lengthSync();
      Uint8List? read(int offset, int size) {
        if (offset < 0 || size < 0 || offset > length || size > length - offset) return null;
        source!.setPositionSync(offset);
        final bytes = source.readSync(size);
        return bytes.length == size ? bytes : null;
      }

      final header = read(0, 64);
      if (header == null ||
          Binary.u32(header, 0) != 0x464c457f ||
          header[4] != 2 ||
          header[5] != 1 ||
          header[6] != 1 ||
          Binary.u16(header, 16) != 3 ||
          Binary.u16(header, 18) != 62 ||
          Binary.u32(header, 20) != 1 ||
          Binary.u16(header, 52) != 64) {
        return false;
      }
      final programCount = Binary.u16(header, 56);
      if (programCount == 0 || programCount > 1024 || Binary.u16(header, 54) != 56) return false;
      final programs = read(Binary.u64(header, 32), programCount * 56);
      if (programs == null) return false;
      final loads = <({int address, int offset, int size, bool executable})>[];
      ({int address, int offset, int size})? dynamic;
      for (var at = 0; at < programs.length; at += 56) {
        final type = Binary.u32(programs, at);
        if (type == 3) return false; // PT_INTERP: a PIE executable.
        if (type != 1 && type != 2) continue;
        final offset = Binary.u64(programs, at + 8);
        final address = Binary.u64(programs, at + 16);
        final size = Binary.u64(programs, at + 32);
        final memory = Binary.u64(programs, at + 40);
        if (offset < 0 || address < 0 || size < 0 || memory < size || offset > length || size > length - offset) {
          return false;
        }
        if (type == 1) {
          loads.add((address: address, offset: offset, size: size, executable: Binary.u32(programs, at + 4) & 1 != 0));
        } else {
          if (dynamic != null) return false;
          dynamic = (address: address, offset: offset, size: size);
        }
      }
      if (loads.isEmpty) return false;
      int? mappedOffset(int address, int size, {bool executable = false}) {
        if (address < 0 || size <= 0) return null;
        for (final load in loads) {
          final delta = address - load.address;
          if ((!executable || load.executable) && delta >= 0 && delta < load.size && size <= load.size - delta) {
            return load.offset + delta;
          }
        }
        return null;
      }

      if (requiredExport == null) return true;
      if (dynamic == null ||
          dynamic.size <= 0 ||
          dynamic.size % 16 != 0 ||
          dynamic.size > 1024 * 1024 ||
          mappedOffset(dynamic.address, dynamic.size) != dynamic.offset) {
        return false;
      }
      final entries = read(dynamic.offset, dynamic.size);
      if (entries == null) return false;
      final runtime = <int, int>{};
      var terminated = false;
      for (var at = 0; at < entries.length; at += 16) {
        final tag = Binary.u64(entries, at);
        if (tag == 0) {
          terminated = true;
          break;
        }
        if (!const {5, 6, 10, 11}.contains(tag)) continue;
        if (runtime.containsKey(tag)) return false;
        runtime[tag] = Binary.u64(entries, at + 8);
      }
      if (!terminated ||
          runtime[11] != 24 ||
          runtime[5] == null ||
          runtime[6] == null ||
          runtime[10] == null ||
          runtime[10]! <= 0 ||
          runtime[10]! > 8 * 1024 * 1024) {
        return false;
      }

      final count = Binary.u16(header, 60);
      if (count == 0 || count > 8192 || Binary.u16(header, 58) != 64) return false;
      final sections = read(Binary.u64(header, 40), count * 64);
      if (sections == null) return false;
      final expected = [...requiredExport.codeUnits, 0];
      for (var index = 0; index < count; index++) {
        final at = index * 64;
        if (Binary.u32(sections, at + 4) != 11) continue; // SHT_DYNSYM
        final size = Binary.u64(sections, at + 32);
        if (Binary.u64(sections, at + 56) != 24 || size <= 0 || size % 24 != 0 || size > 24 * 200000) continue;
        final link = Binary.u32(sections, at + 40);
        if (link >= count || Binary.u32(sections, link * 64 + 4) != 3) continue;
        final stringSize = Binary.u64(sections, link * 64 + 32);
        if (stringSize <= 0 || stringSize > 8 * 1024 * 1024) continue;
        if (Binary.u64(sections, at + 16) != runtime[6] ||
            Binary.u64(sections, link * 64 + 16) != runtime[5] ||
            stringSize != runtime[10] ||
            mappedOffset(runtime[6]!, size) != Binary.u64(sections, at + 24) ||
            mappedOffset(runtime[5]!, stringSize) != Binary.u64(sections, link * 64 + 24)) {
          continue;
        }
        final symbols = read(Binary.u64(sections, at + 24), size);
        final strings = read(Binary.u64(sections, link * 64 + 24), stringSize);
        if (symbols == null || strings == null) continue;
        for (var symbol = 0; symbol < size; symbol += 24) {
          final binding = symbols[symbol + 4] >> 4;
          final visibility = symbols[symbol + 5] & 3;
          if ((binding != 1 && binding != 2) || symbols[symbol + 4] & 15 != 2 || (visibility != 0 && visibility != 3)) {
            continue;
          }
          final section = Binary.u16(symbols, symbol + 6);
          if (section == 0 || section >= count) continue;
          final name = Binary.u32(symbols, symbol);
          if (name > strings.length - expected.length) continue;
          if (!expected.asMap().entries.every((entry) => strings[name + entry.key] == entry.value)) continue;
          final target = section * 64;
          if (Binary.u64(sections, target + 8) & 6 != 6) continue; // SHF_ALLOC | SHF_EXECINSTR
          final address = Binary.u64(sections, target + 16);
          final sectionSize = Binary.u64(sections, target + 32);
          final value = Binary.u64(symbols, symbol + 8);
          final functionSize = Binary.u64(symbols, symbol + 16);
          final delta = value - address;
          if (address < 0 ||
              delta < 0 ||
              sectionSize <= 0 ||
              delta >= sectionSize ||
              functionSize < 0 ||
              functionSize > sectionSize - delta) {
            continue;
          }
          // Section metadata must agree with the file-backed executable loader
          // mapping, not merely claim that these bytes will be executable.
          final mapped = mappedOffset(value, functionSize == 0 ? 1 : functionSize, executable: true);
          if (mapped != null && mapped == Binary.u64(sections, target + 24) + delta) return true;
        }
      }
      return false;
    } on FileSystemException {
      return false;
    } finally {
      source?.closeSync();
    }
  }
}
