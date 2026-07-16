// Test-only minimal ZIP writer: exercises shapes reference tools cannot
// produce on demand (duplicate paths, backslashes, traversal names, data
// descriptors, ZIP64 markers, deliberate corruption).

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

/// One entry for [buildZip]. Stored (method 0) unless overridden.
final class ZipEntrySpec {
  ZipEntrySpec(
    String name,
    String content, {
    this.method = 0,
    this.dataDescriptor = false,
    this.crcOverride,
    this.extra = const [],
    this.externalAttributes = 0,
    this.zip64 = false,
    this.descriptorSignature = true,
    List<int>? nameBytes,
  }) : nameBytes = nameBytes ?? utf8.encode(name),
       content = utf8.encode(content);

  final List<int> nameBytes;
  final List<int> content;
  final int method;
  final bool dataDescriptor;
  final int? crcOverride;
  final List<int> extra;
  final int externalAttributes;

  /// Write sizes as 0xFFFFFFFF markers deferring to a ZIP64 extra field.
  final bool zip64;

  /// Whether the data descriptor (when used) carries the optional
  /// `PK\x07\x08` signature; both layouts exist in the wild.
  final bool descriptorSignature;
}

/// Builds a ZIP archive byte-for-byte.
Uint8List buildZip(
  List<ZipEntrySpec> entries, {
  String comment = '',
  List<int> trailingJunk = const [],
  int? cdOffsetOverride,
  int? totalEntriesOverride,
  int diskNumber = 0,
  bool zip64Eocd = false,
}) {
  final out = BytesBuilder(copy: false);
  final localOffsets = <int>[];

  void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) =>
      out.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  const dosTime = (3 << 11) | (4 << 5) | (6 >> 1); // 03:04:06
  const dosDate = ((2020 - 1980) << 9) | (1 << 5) | 2; // 2020-01-02

  for (final entry in entries) {
    localOffsets.add(out.length);
    final crc =
        entry.crcOverride ?? Crc32.compute(Uint8List.fromList(entry.content));
    final flags = entry.dataDescriptor ? 0x08 : 0;
    u32(0x04034B50);
    u16(20); // version needed
    u16(flags);
    u16(entry.method);
    u16(dosTime);
    u16(dosDate);
    u32(entry.dataDescriptor ? 0 : crc);
    u32(entry.dataDescriptor ? 0 : entry.content.length);
    u32(entry.dataDescriptor ? 0 : entry.content.length);
    u16(entry.nameBytes.length);
    u16(0); // local extra
    out.add(entry.nameBytes);
    out.add(entry.content);
    if (entry.dataDescriptor) {
      if (entry.descriptorSignature) u32(0x08074B50);
      u32(crc);
      u32(entry.content.length);
      u32(entry.content.length);
    }
  }

  void u64(int v) {
    u32(v & 0xFFFFFFFF);
    u32(v ~/ 0x100000000);
  }

  final cdOffset = out.length;
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final crc =
        entry.crcOverride ?? Crc32.compute(Uint8List.fromList(entry.content));
    final zip64Extra =
        entry.zip64
            ? [
              0x01, 0x00, 16, 0, // id 0x0001, size 16
              // usize then csize, 8 bytes each (little-endian; small values)
              entry.content.length & 0xFF,
              (entry.content.length >> 8) & 0xFF,
              0, 0, 0, 0, 0, 0,
              entry.content.length & 0xFF,
              (entry.content.length >> 8) & 0xFF,
              0, 0, 0, 0, 0, 0,
            ]
            : const <int>[];
    u32(0x02014B50);
    u16(20); // version made by (DOS host)
    u16(entry.zip64 ? 45 : 20); // version needed
    u16(entry.dataDescriptor ? 0x08 : 0);
    u16(entry.method);
    u16(dosTime);
    u16(dosDate);
    u32(crc);
    u32(entry.zip64 ? 0xFFFFFFFF : entry.content.length);
    u32(entry.zip64 ? 0xFFFFFFFF : entry.content.length);
    u16(entry.nameBytes.length);
    u16(entry.extra.length + zip64Extra.length);
    u16(0); // comment
    u16(0); // disk start
    u16(0); // internal attrs
    u32(entry.externalAttributes);
    u32(localOffsets[i]);
    out.add(entry.nameBytes);
    out.add(zip64Extra);
    out.add(entry.extra);
  }
  final cdSize = out.length - cdOffset;

  if (zip64Eocd) {
    final eocd64Offset = out.length;
    u32(0x06064B50); // ZIP64 EOCD record
    u64(44); // size of remaining record
    u16(45); // version made by
    u16(45); // version needed
    u32(0); // this disk
    u32(0); // cd disk
    u64(entries.length);
    u64(entries.length);
    u64(cdSize);
    u64(cdOffset);
    u32(0x07064B50); // locator
    u32(0); // disk of eocd64
    u64(eocd64Offset);
    u32(1); // total disks
  }

  final commentBytes = utf8.encode(comment);
  u32(0x06054B50);
  u16(diskNumber);
  u16(diskNumber);
  u16(totalEntriesOverride ?? (zip64Eocd ? 0xFFFF : entries.length));
  u16(totalEntriesOverride ?? (zip64Eocd ? 0xFFFF : entries.length));
  u32(zip64Eocd ? 0xFFFFFFFF : cdSize);
  u32(cdOffsetOverride ?? (zip64Eocd ? 0xFFFFFFFF : cdOffset));
  u16(commentBytes.length);
  out.add(commentBytes);
  out.add(trailingJunk);

  return out.takeBytes();
}

/// A `UT` (0x5455) extended-timestamp extra field carrying [unixMtime].
List<int> utExtra(int unixMtime) => [
  0x55, 0x54, 5, 0, // id, size
  0x01, // flags: mtime present
  unixMtime & 0xFF,
  (unixMtime >> 8) & 0xFF,
  (unixMtime >> 16) & 0xFF,
  (unixMtime >> 24) & 0xFF,
];
