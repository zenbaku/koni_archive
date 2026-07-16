// Test-only RAR4 (v1.5) store-archive builder. rar 7.x only authors v5, so
// this hand-builds v4 container bytes (with correct CRC-16 header checksums
// and per-file CRC-32) to exercise the RAR4 container + store path — and to
// give the fuzz smoke a RAR4 seed, since the committed fixtures are all v5.

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

/// Builds a minimal RAR4 archive with the given `path -> content` entries.
///
/// [unpackVersion] is the raw unpack-version byte written to each file header
/// (default 20). [method] is the raw method byte (default 0x30 = store); pass a
/// compressed value like 0x33 to synthesize a header the reader must reject
/// when [unpackVersion] is not 29 (the data is still written verbatim, so a
/// compressed header is only meaningful for exercising header dispatch).
Uint8List buildRar4Store(
  Map<String, String> files, {
  int unpackVersion = 20,
  int method = 0x30,
  bool solid = false,
}) {
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

  var fileIndex = 0;
  for (final MapEntry(key: name, value: content) in files.entries) {
    final nameBytes = utf8.encode(name);
    final data = utf8.encode(content);
    final headerSize = 7 + 25 + nameBytes.length;
    // In a solid run the first file is the run start (solid flag clear); every
    // later file carries the solid flag (0x10).
    final fhFlags = solid && fileIndex > 0 ? 0x10 : 0x00;
    fileIndex++;
    final body =
        BytesBuilder(copy: false)
          ..add([0x74]) // FILE_HEAD
          ..add(_le16(fhFlags)) // flags
          ..add(_le16(headerSize))
          ..add(_le32(data.length)) // pack size
          ..add(_le32(data.length)) // unpacked size
          ..add([0x00]) // host os = MS-DOS
          ..add(_le32(Crc32.compute(Uint8List.fromList(data))))
          ..add(_le32(0)) // file time
          ..add([unpackVersion]) // unpack version (15/20/26/29…)
          ..add([method]) // method 0x30 = store, 0x31–0x35 = compressed
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
