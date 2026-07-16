@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// Differential vectors from the platform zlib: compress random and
/// structured payloads with `dart:io`'s ZLibCodec (raw deflate), decode
/// with our inflater, expect byte identity. Seeded and replayable.
void main() {
  test('inflate matches platform zlib across shapes and levels', () {
    final seed = DateTime.now().millisecondsSinceEpoch;
    final random = Random(seed);
    printOnFailure('seed: $seed');

    final payloads = <Uint8List>[
      Uint8List(0),
      Uint8List.fromList(List.filled(100000, 0x41)), // highly repetitive
      Uint8List.fromList(
        List.generate(65536, (_) => random.nextInt(256)), // incompressible
      ),
      Uint8List.fromList(
        List.generate(
          200000,
          (i) => i % 3 == 0 ? random.nextInt(8) : (i * 31) & 0xFF,
        ), // mixed
      ),
    ];

    for (final payload in payloads) {
      for (final level in [1, 6, 9]) {
        final compressed = Uint8List.fromList(
          ZLibCodec(level: level, raw: true).encode(payload),
        );
        expect(
          const InflateDecoder().convert(compressed),
          payload,
          reason: 'payload ${payload.length} B at level $level',
        );
        // And through arbitrary chunk splits.
        final out = BytesBuilder(copy: false);
        final inflater = RawInflater(onOutput: out.add);
        var pos = 0;
        while (pos < compressed.length) {
          final next = min(pos + 1 + random.nextInt(4096), compressed.length);
          inflater.addInput(Uint8List.sublistView(compressed, pos, next));
          pos = next;
        }
        inflater.finish();
        expect(out.takeBytes(), payload, reason: 'chunked, level $level');
      }
    }
  });

  test('gzip decode matches platform gzip', () {
    final payload = Uint8List.fromList(
      List.generate(150000, (i) => (i * 17 + i ~/ 100) & 0xFF),
    );
    final compressed = Uint8List.fromList(GZipCodec(level: 9).encode(payload));
    expect(const GzipDecoder().convert(compressed), payload);
  });
}
