import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

/// Size of a TAR block (header or data unit).
const int tarBlockSize = 512;

/// Field layout of a v7/ustar/GNU header block. Offsets/lengths per the
/// POSIX.1 ustar specification and the GNU tar manual.
class TarHeader {
  TarHeader._({
    required this.name,
    required this.mode,
    required this.size,
    required this.mtime,
    required this.typeFlag,
    required this.linkName,
    required this.magicIsUstar,
    required this.magicIsGnu,
    required this.prefix,
    required this.devMajor,
    required this.devMinor,
    required this.gnuSparseIsExtended,
  });

  /// Raw `name` field, decoded (UTF-8, Latin-1 fallback).
  final String name;

  /// Permission bits, or null when unparseable.
  final int? mode;

  /// The `size` field: bytes of data following this header in the archive.
  final int size;

  /// The `mtime` field, seconds since epoch (may be negative), or null.
  final int? mtime;

  /// The single-character type flag (`0`, `\x00`, `1`–`7`, `x`, `g`, `L`,
  /// `K`, `S`, …).
  final int typeFlag;

  /// Raw `linkname` field, decoded.
  final String linkName;

  /// Whether the POSIX `ustar\x00` magic is present (enables `prefix`).
  final bool magicIsUstar;

  /// Whether the old-GNU `ustar  \x00` magic is present.
  final bool magicIsGnu;

  /// POSIX `prefix` field (empty for GNU/v7).
  final String prefix;

  /// Device numbers for character/block device entries, or null.
  final int? devMajor;

  /// Device numbers for character/block device entries, or null.
  final int? devMinor;

  /// Old-GNU sparse header: whether continuation sparse blocks follow.
  final bool gnuSparseIsExtended;

  /// The effective path: POSIX prefix + name.
  String get fullName => prefix.isEmpty ? name : '$prefix/$name';

  /// Parses the 512-byte [block] at archive [offset] (offset used for error
  /// context only).
  ///
  /// Returns null when [block] is all zeroes (end-of-archive marker).
  /// Throws [InvalidHeaderException] when the checksum does not validate.
  static TarHeader? parse(Uint8List block, int offset) {
    assert(block.length == tarBlockSize, 'header must be one block');
    if (_isAllZero(block)) return null;

    _validateChecksum(block, offset);

    final magicIsUstar = _hasBytes(block, 257, const [
      0x75,
      0x73,
      0x74,
      0x61,
      0x72,
      0x00,
    ]); // ustar\0
    final magicIsGnu = _hasBytes(block, 257, const [
      0x75,
      0x73,
      0x74,
      0x61,
      0x72,
      0x20,
      0x20,
      0x00,
    ]); // "ustar  \0"

    final size = parseNumeric(block, 124, 12, offset, 'size') ?? 0;
    if (size < 0) {
      throw InvalidHeaderException(
        'negative size field',
        format: 'tar',
        offset: offset,
      );
    }

    return TarHeader._(
      name: decodeTarString(block, 0, 100),
      mode: parseNumeric(block, 100, 8, offset, 'mode'),
      size: size,
      mtime: parseNumeric(block, 136, 12, offset, 'mtime'),
      typeFlag: block[156],
      linkName: decodeTarString(block, 157, 100),
      magicIsUstar: magicIsUstar,
      magicIsGnu: magicIsGnu,
      prefix: magicIsUstar ? decodeTarString(block, 345, 155) : '',
      devMajor: parseNumeric(block, 329, 8, offset, 'devmajor'),
      devMinor: parseNumeric(block, 337, 8, offset, 'devminor'),
      gnuSparseIsExtended: block[482] != 0,
    );
  }

  /// Whether [block] has a plausible tar header checksum (used by format
  /// detection for magic-less pre-POSIX v7 tars, §5). Never throws.
  static bool checksumLooksValid(Uint8List block) {
    if (block.length != tarBlockSize || _isAllZero(block)) return false;
    try {
      _validateChecksum(block, 0);
      return true;
    } on ArchiveException {
      return false;
    }
  }

  static void _validateChecksum(Uint8List block, int offset) {
    final stored = parseNumeric(block, 148, 8, offset, 'chksum');
    if (stored == null) {
      throw InvalidHeaderException(
        'unparseable header checksum',
        format: 'tar',
        offset: offset,
      );
    }
    // Sum with the chksum field itself read as 8 spaces. Historic tars
    // sometimes summed *signed* bytes; accept either sum (like GNU tar).
    var unsigned = 0;
    var signed = 0;
    for (var i = 0; i < tarBlockSize; i++) {
      final byte = (i >= 148 && i < 156) ? 0x20 : block[i];
      unsigned += byte;
      signed += byte < 128 ? byte : byte - 256;
    }
    if (stored != unsigned && stored != signed) {
      throw InvalidHeaderException(
        'header checksum mismatch (stored $stored, computed $unsigned)',
        format: 'tar',
        offset: offset,
      );
    }
  }

  static bool _isAllZero(Uint8List block) {
    for (final byte in block) {
      if (byte != 0) return false;
    }
    return true;
  }

  static bool _hasBytes(Uint8List block, int at, List<int> expected) {
    for (var i = 0; i < expected.length; i++) {
      if (block[at + i] != expected[i]) return false;
    }
    return true;
  }
}

/// Parses a tar numeric field: octal ASCII (space/NUL padded) or GNU
/// base-256 (first byte has the high bit set; big-endian two's complement).
///
/// Returns null for an empty/blank field. Throws [InvalidHeaderException]
/// for garbage, and [UnsupportedFeatureException] when a value exceeds
/// 2^53 - 1 (the exact-integer cap on every platform for uniform behavior;
/// ~9 PB dwarfs any real archive field).
int? parseNumeric(
  Uint8List block,
  int start,
  int length,
  int headerOffset,
  String field,
) {
  if (block[start] & 0x80 != 0) {
    return _parseBase256(block, start, length, headerOffset, field);
  }
  // Octal: skip leading spaces/NULs, stop at first space/NUL after digits.
  var value = 0;
  var seenDigit = false;
  for (var i = start; i < start + length; i++) {
    final byte = block[i];
    if (byte == 0x20 || byte == 0x00) {
      if (seenDigit) break;
      continue;
    }
    if (byte < 0x30 || byte > 0x37) {
      throw InvalidHeaderException(
        'invalid octal digit 0x${byte.toRadixString(16)} in $field field',
        format: 'tar',
        offset: headerOffset + start,
      );
    }
    value = value * 8 + (byte - 0x30);
    if (value > _maxSafeValue) {
      throw UnsupportedFeatureException(
        '$field value exceeds the supported integer range',
        format: 'tar',
        offset: headerOffset + start,
      );
    }
    seenDigit = true;
  }
  return seenDigit ? value : null;
}

// 2^53 - 1: the largest integer dart2js models exactly, used as the cap on
// every platform (uniform behavior; ~9 PB dwarfs any real archive field).
const int _maxSafeValue = 0x1FFFFFFFFFFFFF;
// Pre-shift bound for the base-256 accumulator. Computed with ~/ because
// dart2js bitwise shifts truncate to 32 bits.
const int _maxAccumulator = _maxSafeValue ~/ 256;

int _parseBase256(
  Uint8List block,
  int start,
  int length,
  int headerOffset,
  String field,
) {
  // The field is an n-byte big-endian two's-complement integer whose top
  // bit (0x80 of the first byte) is the base-256 marker and whose next bit
  // (0x40) is the sign. Negative values appear only in mtime in practice.
  var value = block[start] & 0x7F;
  if (value & 0x40 != 0) value -= 0x80; // sign-extend the 7-bit top byte
  for (var i = start + 1; i < start + length; i++) {
    if (value > _maxAccumulator || value < -_maxAccumulator) {
      throw UnsupportedFeatureException(
        '$field value exceeds the supported integer range',
        format: 'tar',
        offset: headerOffset + start,
      );
    }
    // Multiplication (not shifting) keeps two's complement arithmetic
    // correct for negative accumulators on every platform.
    value = value * 256 + block[i];
  }
  return value;
}

/// Decodes a NUL-terminated tar string field: UTF-8 first, Latin-1 fallback
/// (header encodings are unspecified in old formats; never throw, §7).
String decodeTarString(Uint8List block, int start, int length) {
  var end = start;
  while (end < start + length && block[end] != 0) {
    end++;
  }
  final bytes = Uint8List.sublistView(block, start, end);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}
