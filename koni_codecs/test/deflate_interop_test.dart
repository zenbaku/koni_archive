@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// Interop DoD: our deflate output must decompress with the platform zlib
/// (`dart:io`'s raw ZLibCodec), the real check that we emit standard
/// deflate, not just something our own inflate happens to accept.
void main() {
  Uint8List zlibInflate(Uint8List raw) =>
      Uint8List.fromList(ZLibCodec(raw: true).decode(raw));

  test('platform zlib decodes our deflate across shapes', () {
    final random = Random(7);
    final payloads = <Uint8List>[
      Uint8List(0),
      Uint8List.fromList(utf8.encode('the quick brown fox ' * 300)),
      Uint8List.fromList(List.filled(100000, 0x41)),
      Uint8List.fromList(List.generate(65536, (_) => random.nextInt(256))),
      Uint8List.fromList(
        List.generate(250000, (i) => ((i * 7) ^ (i >> 3)) & 0xFF),
      ),
    ];
    for (final payload in payloads) {
      final compressed = const DeflateEncoder().convert(payload);
      expect(
        zlibInflate(compressed),
        payload,
        reason: 'platform zlib must decode our ${payload.length}-byte output',
      );
    }
  });

  test('our deflate wrapped in gzip decodes with the platform gzip', () {
    // Frame our raw deflate as a gzip member and let dart:io's GZipCodec
    // (native zlib) decode it, proves bit-stream compatibility end to end.
    final payload = Uint8List.fromList(utf8.encode('koni archive ' * 2000));
    final deflate = const DeflateEncoder().convert(payload);
    final crc = _crc32(payload);
    final gz =
        BytesBuilder(copy: false)
          ..add([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]) // gzip header
          ..add(deflate)
          ..add(_le32(crc))
          ..add(_le32(payload.length));
    expect(Uint8List.fromList(GZipCodec().decode(gz.takeBytes())), payload);
  });
}

List<int> _le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

int _crc32(Uint8List data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
