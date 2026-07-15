// Test-only RAR4 (v1.5) store-archive builder. rar 7.x only authors v5, so
// this hand-builds v4 container bytes (with correct CRC-16 header checksums
// and per-file CRC-32) to exercise the RAR4 container + store path — and to
// give the fuzz smoke a RAR4 seed, since the committed fixtures are all v5.

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

/// Builds a minimal RAR4 archive with the given stored `path -> content`
/// entries.
Uint8List buildRar4Store(Map<String, String> files) {
  final out = BytesBuilder(copy: false);
  out.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]); // signature

  final main =
      BytesBuilder(copy: false)
        ..add([0x73]) // MAIN_HEAD
        ..add([0x00, 0x00]) // flags
        ..add([0x0D, 0x00]) // size = 13
        ..add([0x00, 0x00]) // highposav
        ..add([0x00, 0x00, 0x00, 0x00]); // posav
  out.add(_withHeaderCrc(main.takeBytes()));

  for (final MapEntry(key: name, value: content) in files.entries) {
    final nameBytes = utf8.encode(name);
    final data = utf8.encode(content);
    final headerSize = 7 + 25 + nameBytes.length;
    final body =
        BytesBuilder(copy: false)
          ..add([0x74]) // FILE_HEAD
          ..add([0x00, 0x00]) // flags
          ..add(_le16(headerSize))
          ..add(_le32(data.length)) // pack size
          ..add(_le32(data.length)) // unpacked size
          ..add([0x00]) // host os = MS-DOS
          ..add(_le32(Crc32.compute(Uint8List.fromList(data))))
          ..add(_le32(0)) // file time
          ..add([20]) // unpack version
          ..add([0x30]) // method 0x30 = store
          ..add(_le16(nameBytes.length))
          ..add(_le32(0)) // attributes
          ..add(nameBytes);
    out.add(_withHeaderCrc(body.takeBytes()));
    out.add(data);
  }

  final end =
      BytesBuilder(copy: false)
        ..add([0x7B]) // ENDARC_HEAD
        ..add([0x00, 0x00])
        ..add([0x07, 0x00]);
  out.add(_withHeaderCrc(end.takeBytes()));
  return out.takeBytes();
}

/// Prepends the CRC-16 (low 16 bits of the CRC-32 over the header from the
/// type byte onward) to a header body.
Uint8List _withHeaderCrc(Uint8List headerFromType) {
  final crc = Crc32.compute(headerFromType) & 0xFFFF;
  return Uint8List.fromList([crc & 0xFF, (crc >> 8) & 0xFF, ...headerFromType]);
}

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];
