import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'cp437.dart';

/// ZIP structure signatures (little-endian on disk; compared byte-wise).
const int eocdSignature = 0x06054B50;

/// `PK\x06\x07` — ZIP64 end-of-central-directory locator.
const int zip64LocatorSignature = 0x07064B50;

/// `PK\x01\x02` — central directory file header.
const int centralHeaderSignature = 0x02014B50;

/// `PK\x03\x04` — local file header.
const int localHeaderSignature = 0x04034B50;

/// Parsed end-of-central-directory record, positioned within the source.
final class Eocd {
  Eocd._({
    required this.totalEntries,
    required this.centralDirectorySize,
    required this.centralDirectoryOffset,
    required this.eocdOffset,
    required this.prefixLength,
    required this.isZip64,
  });

  /// Whether ZIP64 end-of-central-directory structures were used.
  final bool isZip64;

  /// Total entry count from the EOCD.
  final int totalEntries;

  /// Central directory size in bytes.
  final int centralDirectorySize;

  /// Central directory offset *as recorded* (before prefix adjustment).
  final int centralDirectoryOffset;

  /// Absolute offset of the EOCD record in the source.
  final int eocdOffset;

  /// Bytes of non-ZIP prefix (self-extracting stub, §5/§15): the recorded
  /// offsets are relative to the original archive start, so every offset
  /// must be shifted by this delta.
  final int prefixLength;

  /// Locates and parses the EOCD by scanning backwards from EOF (§5): the
  /// comment field can push the record up to ~64 KiB from the end. Prefers
  /// a candidate whose comment length exactly reaches EOF; falls back to
  /// the last signature found (trailing junk happens in the wild — matches
  /// Info-ZIP's tolerance; see doc/notes.md).
  static Future<Eocd> find(ByteSource source) async {
    if (source.length < 22) {
      throw InvalidHeaderException(
        'too short to be a ZIP archive (${source.length} bytes)',
        format: 'zip',
      );
    }
    final tailLength = math.min(source.length, 22 + 0xFFFF);
    final tailStart = source.length - tailLength;
    final tail = await source.read(tailStart, tailLength);

    int? fallback;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4B &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        final commentLength = tail[i + 20] | (tail[i + 21] << 8);
        if (i + 22 + commentLength == tail.length) {
          return Eocd._parse(source, tail, tailStart, i);
        }
        fallback ??= i;
      }
    }
    if (fallback != null) {
      return Eocd._parse(source, tail, tailStart, fallback);
    }
    throw InvalidHeaderException(
      'no end-of-central-directory record found',
      format: 'zip',
      offset: source.length,
    );
  }

  static Future<Eocd> _parse(
    ByteSource source,
    Uint8List tail,
    int tailStart,
    int i,
  ) async {
    final reader = ByteReader(tail, baseOffset: tailStart)..position = i + 4;
    final diskNumber = reader.readUint16le();
    final cdDisk = reader.readUint16le();
    final entriesOnDisk = reader.readUint16le();
    final totalEntries = reader.readUint16le();
    final cdSize = reader.readUint32le();
    final cdOffset = reader.readUint32le();
    final eocdOffset = tailStart + i;

    final markers =
        totalEntries == 0xFFFF ||
        cdSize == 0xFFFFFFFF ||
        cdOffset == 0xFFFFFFFF;
    final hasLocator = await _hasZip64Locator(source, eocdOffset);
    if (markers && !hasLocator) {
      throw CorruptArchiveException(
        'ZIP64 markers in the end-of-central-directory record but no '
        'ZIP64 locator precedes it',
        format: 'zip',
        offset: eocdOffset,
      );
    }
    if (hasLocator) {
      return _parseZip64(source, eocdOffset, diskNumber, cdDisk);
    }
    if (diskNumber != 0 || cdDisk != 0 || entriesOnDisk != totalEntries) {
      throw UnsupportedFeatureException(
        'multi-volume (spanned) ZIP archives are not supported',
        format: 'zip',
        offset: eocdOffset,
      );
    }

    return _validated(
      totalEntries: totalEntries,
      cdSize: cdSize,
      cdOffset: cdOffset,
      cdEnd: eocdOffset,
      eocdOffset: eocdOffset,
      isZip64: false,
    );
  }

  /// Locates and parses the ZIP64 end-of-central-directory record (M7).
  ///
  /// The locator's recorded offset is relative to the original archive
  /// start (wrong for prefixed archives), so the record is found by
  /// scanning backwards from the locator — writers place it immediately
  /// before, but the record is extensible, so a bounded window is searched.
  static Future<Eocd> _parseZip64(
    ByteSource source,
    int eocdOffset,
    int diskNumber,
    int cdDisk,
  ) async {
    final locatorOffset = eocdOffset - 20;
    final window = locatorOffset < 8192 ? locatorOffset : 8192;
    final bytes = await source.read(locatorOffset - window, window);
    var recordAt = -1;
    for (var i = window - 56; i >= 0; i--) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4B &&
          bytes[i + 2] == 0x06 &&
          bytes[i + 3] == 0x06) {
        recordAt = i;
        break;
      }
    }
    if (recordAt < 0) {
      throw CorruptArchiveException(
        'ZIP64 locator present but no ZIP64 end-of-central-directory '
        'record found before it',
        format: 'zip',
        offset: locatorOffset,
      );
    }
    final recordOffset = locatorOffset - window + recordAt;
    final reader = ByteReader(bytes, baseOffset: locatorOffset - window)
      ..position = recordAt + 4;
    reader.skip(8); // size of record
    reader.skip(4); // version made by / version needed
    final disk = reader.readUint32le();
    final cd64Disk = reader.readUint32le();
    final entriesOnDisk = reader.readUint64le();
    final totalEntries = reader.readUint64le();
    final cdSize = reader.readUint64le();
    final cdOffset = reader.readUint64le();

    if (disk != 0 ||
        cd64Disk != 0 ||
        (diskNumber != 0 && diskNumber != 0xFFFF) ||
        (cdDisk != 0 && cdDisk != 0xFFFF) ||
        entriesOnDisk != totalEntries) {
      throw UnsupportedFeatureException(
        'multi-volume (spanned) ZIP archives are not supported',
        format: 'zip',
        offset: recordOffset,
      );
    }
    return _validated(
      totalEntries: totalEntries,
      cdSize: cdSize,
      cdOffset: cdOffset,
      cdEnd: recordOffset,
      eocdOffset: eocdOffset,
      isZip64: true,
    );
  }

  static Eocd _validated({
    required int totalEntries,
    required int cdSize,
    required int cdOffset,
    required int cdEnd,
    required int eocdOffset,
    required bool isZip64,
  }) {
    // Never trust header fields (§7): the central directory must fit
    // before whatever record marks its end.
    if (cdSize > cdEnd || cdOffset > cdEnd - cdSize) {
      throw CorruptArchiveException(
        'central directory (offset $cdOffset, size $cdSize) does not fit '
        'before its end record at $cdEnd',
        format: 'zip',
        offset: eocdOffset,
      );
    }
    // Self-extracting/prefixed archives: recorded offsets are relative to
    // the original archive start. The gap between where the central
    // directory should end (cdOffset + cdSize) and where it actually ends
    // is the prefix length.
    return Eocd._(
      totalEntries: totalEntries,
      centralDirectorySize: cdSize,
      centralDirectoryOffset: cdOffset,
      eocdOffset: eocdOffset,
      prefixLength: cdEnd - cdSize - cdOffset,
      isZip64: isZip64,
    );
  }

  static Future<bool> _hasZip64Locator(
    ByteSource source,
    int eocdOffset,
  ) async {
    if (eocdOffset < 20) return false;
    final bytes = await source.read(eocdOffset - 20, 4);
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x06 &&
        bytes[3] == 0x07;
  }
}

/// One parsed central-directory record plus what the reader needs to open
/// its content.
final class CentralEntry {
  CentralEntry._({
    required this.entry,
    required this.methodId,
    required this.effectiveMethodId,
    required this.localHeaderOffset,
    required this.compressedSize,
    required this.flags,
    required this.dosTime,
    required this.aesExtra,
  });

  /// The public entry model.
  final ArchiveEntry entry;

  /// Raw ZIP method id from the record (0 = stored, 8 = deflate, 99 = the
  /// WinZip AES wrapper).
  final int methodId;

  /// Compression method to apply *after* decryption. Equals [methodId]
  /// except for AES (method 99), where it is the inner method named by the
  /// 0x9901 extra field.
  final int effectiveMethodId;

  /// Absolute offset of the local file header (prefix-adjusted).
  final int localHeaderOffset;

  /// Stored byte count of the content in the archive — including any
  /// encryption header/salt/MAC overhead.
  final int compressedSize;

  /// General-purpose bit flags (bit 0 = encrypted, bit 3 = data
  /// descriptor). Needed to pick the traditional-cipher password check.
  final int flags;

  /// Raw DOS mod-time field — the traditional cipher's check byte when the
  /// entry carries a data descriptor (bit 3).
  final int dosTime;

  /// The 0x9901 extra payload when [methodId] is 99, else null.
  final Uint8List? aesExtra;

  /// Parses the whole central directory.
  static Future<List<CentralEntry>> parseDirectory(
    ByteSource source,
    Eocd eocd,
    ArchiveReadOptions options,
  ) async {
    // Each record is at least 46 bytes: an entry count that cannot fit is
    // hostile (§7 — fail cleanly, no OOM).
    if (eocd.totalEntries > eocd.centralDirectorySize ~/ 46) {
      throw CorruptArchiveException(
        '${eocd.totalEntries} entries cannot fit in a '
        '${eocd.centralDirectorySize}-byte central directory',
        format: 'zip',
        offset: eocd.eocdOffset,
      );
    }
    final cdStart = eocd.centralDirectoryOffset + eocd.prefixLength;
    final bytes = await source.read(cdStart, eocd.centralDirectorySize);
    final reader = ByteReader(bytes, baseOffset: cdStart);

    final entries = <CentralEntry>[];
    for (var i = 0; i < eocd.totalEntries; i++) {
      entries.add(_parseOne(reader, eocd.prefixLength, options));
    }
    return entries;
  }

  static CentralEntry _parseOne(
    ByteReader reader,
    int prefixLength,
    ArchiveReadOptions options,
  ) {
    final recordOffset = reader.position;
    if (reader.readUint32le() != centralHeaderSignature) {
      throw InvalidHeaderException(
        'bad central directory header signature',
        format: 'zip',
        offset: recordOffset,
      );
    }
    final versionMadeBy = reader.readUint16le();
    reader.skip(2); // version needed
    final flags = reader.readUint16le();
    final methodId = reader.readUint16le();
    final dosTime = reader.readUint16le();
    final dosDate = reader.readUint16le();
    final crc32 = reader.readUint32le();
    var compressedSize = reader.readUint32le();
    var uncompressedSize = reader.readUint32le();
    final nameLength = reader.readUint16le();
    final extraLength = reader.readUint16le();
    final commentLength = reader.readUint16le();
    final diskStart = reader.readUint16le();
    reader.skip(2); // internal attributes
    final externalAttributes = reader.readUint32le();
    var localHeaderOffset = reader.readUint32le();
    final nameBytes = reader.readBytes(nameLength);
    final extra = reader.readBytes(extraLength);
    reader.skip(commentLength);

    // ZIP64 (M7): 0xFFFFFFFF/0xFFFF markers defer to the 0x0001 extra
    // field, whose 64-bit values appear in a fixed order, one per marker.
    if (compressedSize == 0xFFFFFFFF ||
        uncompressedSize == 0xFFFFFFFF ||
        localHeaderOffset == 0xFFFFFFFF ||
        diskStart == 0xFFFF) {
      final zip64 = _findExtra(extra, 0x0001);
      if (zip64 == null) {
        throw CorruptArchiveException(
          'ZIP64 markers without a ZIP64 extra field',
          format: 'zip',
          offset: recordOffset,
        );
      }
      final z = ByteReader(zip64, baseOffset: recordOffset);
      if (uncompressedSize == 0xFFFFFFFF) uncompressedSize = z.readUint64le();
      if (compressedSize == 0xFFFFFFFF) compressedSize = z.readUint64le();
      if (localHeaderOffset == 0xFFFFFFFF) localHeaderOffset = z.readUint64le();
      if (diskStart == 0xFFFF && z.remaining >= 4 && z.readUint32le() != 0) {
        throw UnsupportedFeatureException(
          'multi-volume (spanned) ZIP archives are not supported',
          format: 'zip',
          offset: recordOffset,
        );
      }
    }

    final utf8Flagged = flags & (1 << 11) != 0;
    final rawName =
        !utf8Flagged && options.entryNameDecoder != null
            ? options.entryNameDecoder!(Uint8List.fromList(nameBytes))
            : decodeZipString(nameBytes, utf8Flagged: utf8Flagged);
    final normalized = normalizeEntryPath(rawName);

    // Encryption (M7 polish): traditional (bit 0), strong (bit 6), or
    // AE-x (method 99, whose 0x9901 extra names the real inner method).
    final isEncrypted = flags & 0x1 != 0 || flags & 0x40 != 0 || methodId == 99;
    var effectiveMethodId = methodId;
    Uint8List? aesExtra;
    if (methodId == 99) {
      final aes = _findExtra(extra, 0x9901);
      if (aes != null && aes.length >= 7) {
        aesExtra = aes;
        effectiveMethodId = aes[5] | (aes[6] << 8);
      }
    }
    final unixHost = (versionMadeBy >> 8) == 3;
    final unixMode = unixHost ? (externalAttributes >> 16) & 0xFFFF : null;
    final isDirectory =
        rawName.endsWith('/') ||
        rawName.endsWith(r'\') ||
        (externalAttributes & 0x10) != 0 /* DOS directory bit */ ||
        (unixMode != null && (unixMode & 0xF000) == 0x4000);
    final isSymlink = unixMode != null && (unixMode & 0xF000) == 0xA000;

    final entry = ArchiveEntry(
      path: normalized.path,
      pathEscapedRoot: normalized.escapedRoot,
      type:
          isDirectory
              ? ArchiveEntryType.directory
              : isSymlink
              ? ArchiveEntryType.symlink
              : ArchiveEntryType.file,
      uncompressedSize: uncompressedSize,
      compressedSize: compressedSize,
      compression:
          methodId == 99
              ? _compression(effectiveMethodId)
              : _compression(methodId),
      modified: _extraTime(extra) ?? _dosTime(dosDate, dosTime),
      posixMode: unixMode == null ? null : unixMode & 0xFFF,
      crc32: crc32,
      isEncrypted: isEncrypted,
      // ZIP records no symlink target as metadata: the target is the
      // entry's *content* (read it via openRead). linkTarget stays null.
    );
    return CentralEntry._(
      entry: entry,
      methodId: methodId,
      effectiveMethodId: effectiveMethodId,
      localHeaderOffset: localHeaderOffset + prefixLength,
      compressedSize: compressedSize,
      flags: flags,
      dosTime: dosTime,
      aesExtra: aesExtra,
    );
  }

  /// Finds an extra-field payload by id. Tolerates truncated trailing
  /// extra data (seen in the wild): stops parsing rather than failing the
  /// entry.
  static Uint8List? _findExtra(Uint8List extra, int wantedId) {
    var pos = 0;
    while (pos + 4 <= extra.length) {
      final id = extra[pos] | (extra[pos + 1] << 8);
      final size = extra[pos + 2] | (extra[pos + 3] << 8);
      if (id == wantedId && pos + 4 + size <= extra.length) {
        return Uint8List.sublistView(extra, pos + 4, pos + 4 + size);
      }
      pos += 4 + size;
    }
    return null;
  }

  /// Extended-timestamp extra field (0x5455 "UT"): unix mtime, UTC,
  /// 1-second precision — better than the DOS timestamp when present.
  static DateTime? _extraTime(Uint8List extra) {
    var pos = 0;
    while (pos + 4 <= extra.length) {
      final id = extra[pos] | (extra[pos + 1] << 8);
      final size = extra[pos + 2] | (extra[pos + 3] << 8);
      if (id == 0x5455 && size >= 5 && pos + 4 + 5 <= extra.length) {
        final flags = extra[pos + 4];
        if (flags & 0x1 != 0) {
          final seconds =
              extra[pos + 5] |
              (extra[pos + 6] << 8) |
              (extra[pos + 7] << 16) |
              (extra[pos + 8] << 24);
          return DateTime.fromMillisecondsSinceEpoch(
            seconds * 1000,
            isUtc: true,
          );
        }
      }
      pos += 4 + size;
    }
    return null;
  }

  /// DOS timestamps are local wall time with 2-second resolution and no
  /// zone information; the wall time is exposed *as if* UTC — documented
  /// lossiness (§8).
  static DateTime? _dosTime(int dosDate, int dosTime) {
    if (dosDate == 0) return null;
    return DateTime.utc(
      1980 + ((dosDate >> 9) & 0x7F),
      (dosDate >> 5) & 0xF,
      dosDate & 0x1F,
      (dosTime >> 11) & 0x1F,
      (dosTime >> 5) & 0x3F,
      (dosTime & 0x1F) * 2,
    );
  }

  static ArchiveCompression _compression(int methodId) => switch (methodId) {
    0 => ArchiveCompression.stored,
    8 => ArchiveCompression.deflate,
    9 => ArchiveCompression.deflate64,
    12 => ArchiveCompression.bzip2,
    14 => ArchiveCompression.lzma,
    93 => ArchiveCompression.zstd,
    98 => ArchiveCompression.ppmd,
    _ => ArchiveCompression.unknown(methodId),
  };
}
