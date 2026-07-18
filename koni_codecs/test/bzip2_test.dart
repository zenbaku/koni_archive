@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// Fixtures authored with bzip2(1) 1.0.8; see test/fixtures/bzip2/README.md.
Uint8List _bz2(String name) =>
    Uint8List.fromList(File('test/fixtures/bzip2/$name').readAsBytesSync());

Uint8List _decode(String name) => const Bzip2Decoder().convert(_bz2(name));

// Deterministic reconstructions of the compressed inputs.
Uint8List get _tiny => Uint8List.fromList('hello bzip2 world\n'.codeUnits);
Uint8List get _text => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 2000).codeUnits,
);
Uint8List get _multi =>
    Uint8List.fromList(List.generate(260000, (i) => (i * 7 + (i >> 3)) & 0xFF));
Uint8List get _random {
  // The generator's LCG; exact on the VM (64-bit ints).
  var x = 123456789;
  return Uint8List.fromList(
    List.generate(50000, (_) {
      x = (1103515245 * x + 12345) & 0x7FFFFFFF;
      return x & 0xFF;
    }),
  );
}

void main() {
  test('empty stream decodes to nothing', () {
    expect(_decode('empty.bz2'), isEmpty);
  });

  test('a tiny single-block stream decodes', () {
    expect(_decode('tiny.bz2'), _tiny);
  });

  test('a compressible single-block stream decodes', () {
    expect(_decode('text.bz2'), _text);
  });

  test('a multi-block stream decodes (100 KiB blocks)', () {
    expect(_decode('multi.bz2'), _multi);
  });

  test('an incompressible stream decodes', () {
    expect(_decode('random.bz2'), _random);
  });

  test('concatenated streams decode end to end', () {
    expect(_decode('concat.bz2'), Uint8List.fromList([..._tiny, ..._text]));
  });

  test('the Converter one-shot equals a chunked conversion', () {
    final out = <int>[];
    final sink = const Bzip2Decoder().startChunkedConversion(
      ByteConversionSink.withCallback((bytes) => out.addAll(bytes)),
    );
    final compressed = _bz2('text.bz2');
    for (var i = 0; i < compressed.length; i += 7) {
      final end = (i + 7 < compressed.length) ? i + 7 : compressed.length;
      sink.add(Uint8List.sublistView(compressed, i, end));
    }
    sink.close();
    expect(Uint8List.fromList(out), _text);
  });

  group('malformed input throws FormatException', () {
    test('bad magic', () {
      expect(
        () => const Bzip2Decoder().convert(
          Uint8List.fromList('not a bzip2'.codeUnits),
        ),
        throwsFormatException,
      );
    });

    test('truncated stream', () {
      final full = _bz2('text.bz2');
      expect(
        () => const Bzip2Decoder().convert(
          Uint8List.sublistView(full, 0, full.length - 8),
        ),
        throwsFormatException,
      );
    });

    test('a corrupted block fails its CRC', () {
      final bytes = _bz2('tiny.bz2');
      bytes[bytes.length - 6] ^= 0x10;
      expect(() => const Bzip2Decoder().convert(bytes), throwsFormatException);
    });
  });

  test(
    'fuzz: mutated fixtures decode or throw FormatException only',
    () {
      // The inverse BWT (origPtr, block overflow) is the fuzz-sensitive path:
      // corruption must surface as a typed FormatException, never a RangeError,
      // never OOB, never a hang or unbounded output. Time-budgeted so CI's
      // KONI_ARCHIVE_FUZZ_SECONDS (60 s) gives the BWT its full share.
      final budget = Duration(
        seconds:
            int.tryParse(
              Platform.environment['KONI_ARCHIVE_FUZZ_SECONDS'] ?? '',
            ) ??
            5,
      );
      final seed = DateTime.now().millisecondsSinceEpoch;
      final random = Random(seed);
      printOnFailure('fuzz seed: $seed');
      final corpus = [
        _bz2('tiny.bz2'),
        _bz2('text.bz2'),
        _bz2('multi.bz2'),
        _bz2('random.bz2'),
      ];

      final deadline = DateTime.now().add(budget);
      var iterations = 0;
      while (DateTime.now().isBefore(deadline)) {
        iterations++;
        final base = corpus[random.nextInt(corpus.length)];
        final bytes = Uint8List.fromList(base);
        final flips = 1 + random.nextInt(8);
        for (var i = 0; i < flips; i++) {
          final at = random.nextInt(bytes.length);
          bytes[at] ^= 1 << random.nextInt(8);
        }
        try {
          final out = const Bzip2Decoder().convert(bytes);
          // A block is bounded to 900 KiB; the corpus is at most 3 blocks.
          expect(out.length, lessThan(4 * 900000));
        } on FormatException {
          // typed: fine
        }
      }
      printOnFailure('completed $iterations iterations');
    },
    tags: ['fuzz'],
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
