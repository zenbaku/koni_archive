@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// A skippable frame: magic (LE) + 4-byte LE length + payload.
Uint8List _skippableFrame(int magic, List<int> payload) => Uint8List.fromList([
  magic & 0xFF,
  (magic >> 8) & 0xFF,
  (magic >> 16) & 0xFF,
  (magic >> 24) & 0xFF,
  payload.length & 0xFF,
  (payload.length >> 8) & 0xFF,
  (payload.length >> 16) & 0xFF,
  (payload.length >> 24) & 0xFF,
  ...payload,
]);

/// Fixtures authored with zstd(1) 1.5.7; see test/fixtures/zstd/README.md.
Uint8List _fx(String name) =>
    Uint8List.fromList(File('test/fixtures/zstd/$name').readAsBytesSync());

Uint8List _decode(String name) => const ZstdDecoder().convert(_fx(name));

void main() {
  group('decodes real zstd output', () {
    for (final name in [
      'empty',
      'tiny',
      'rle',
      'text',
      'big',
      'rand',
      'prose',
      'mixed',
      'dprose',
    ]) {
      test('$name (byte-exact, checksum verified)', () {
        expect(_decode('$name.zst'), _fx('$name.bin'));
      });
    }

    test('concatenated frames', () {
      expect(
        _decode('concat.zst'),
        Uint8List.fromList([..._fx('tiny.bin'), ..._fx('text.bin')]),
      );
    });

    test('a checksummed frame', () {
      expect(_decode('text_check.zst'), _fx('text.bin'));
    });

    test('skippable frames are skipped', () {
      // zstd never emits a skippable frame on its own, so build ones by hand
      // and wrap a real frame with a skippable frame before and after.
      final stream = Uint8List.fromList([
        ..._skippableFrame(0x184D2A50, [1, 2, 3, 4]),
        ..._fx('text.zst'),
        ..._skippableFrame(0x184D2A5F, 'ignored metadata'.codeUnits),
      ]);
      expect(const ZstdDecoder().convert(stream), _fx('text.bin'));
    });
  });

  group('malformed input throws FormatException', () {
    test('bad magic', () {
      expect(
        () => const ZstdDecoder().convert(
          Uint8List.fromList('not zstd at all!'.codeUnits),
        ),
        throwsFormatException,
      );
    });

    test('truncated frame', () {
      final full = _fx('prose.zst');
      expect(
        () => const ZstdDecoder().convert(
          Uint8List.sublistView(full, 0, full.length - 10),
        ),
        throwsFormatException,
      );
    });

    test('a corrupted block fails (checksum or structure)', () {
      final bytes = _fx('prose.zst');
      bytes[bytes.length - 8] ^= 0x55;
      expect(() => const ZstdDecoder().convert(bytes), throwsFormatException);
    });
  });

  test(
    'fuzz: mutated fixtures decode or throw FormatException only',
    () {
      final seed = DateTime.now().millisecondsSinceEpoch;
      final random = Random(seed);
      printOnFailure('fuzz seed: $seed');
      final corpus = [
        _fx('tiny.zst'),
        _fx('rle.zst'),
        _fx('text.zst'),
        _fx('prose.zst'),
        _fx('mixed.zst'),
        _fx('dprose.zst'),
      ];
      final budget = Duration(
        seconds:
            int.tryParse(
              Platform.environment['KONI_ARCHIVE_FUZZ_SECONDS'] ?? '',
            ) ??
            5,
      );
      final deadline = DateTime.now().add(budget);
      var iters = 0;
      while (DateTime.now().isBefore(deadline)) {
        iters++;
        final base = corpus[random.nextInt(corpus.length)];
        final bytes = Uint8List.fromList(base);
        final flips = 1 + random.nextInt(8);
        for (var i = 0; i < flips; i++) {
          bytes[random.nextInt(bytes.length)] ^= 1 << random.nextInt(8);
        }
        try {
          final out = const ZstdDecoder().convert(bytes);
          expect(out.length, lessThan(1 << 27));
        } on FormatException {
          // typed: fine
        }
      }
      printOnFailure('completed $iters iterations');
    },
    tags: ['fuzz'],
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
