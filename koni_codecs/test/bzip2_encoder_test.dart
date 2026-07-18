@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

Uint8List _encode(Uint8List data, {int blockSize100k = 9}) =>
    Bzip2Encoder(blockSize100k: blockSize100k).encode(data);

Uint8List _roundTrip(Uint8List data, {int blockSize100k = 9}) =>
    const Bzip2Decoder().convert(_encode(data, blockSize100k: blockSize100k));

/// Decodes [bz2] with the real `bzip2` binary, or null when it is unavailable.
Future<Uint8List?> _bzip2Decode(Uint8List bz2) async {
  final ProcessResult probe;
  try {
    probe = await Process.run('bzip2', ['--help']);
  } on ProcessException {
    return null;
  }
  // `bzip2 --help` exits 0 and prints to stderr; any successful spawn is enough.
  if (probe.exitCode != 0 && probe.exitCode != 1) return null;
  final proc = await Process.start('bzip2', ['-dc']);
  proc.stdin.add(bz2);
  await proc.stdin.close();
  final out = <int>[];
  final collect = proc.stdout.forEach(out.addAll);
  final err = await proc.stderr.transform(systemEncoding.decoder).join();
  await collect;
  final code = await proc.exitCode;
  if (code != 0) fail('bzip2 -d failed (exit $code): $err');
  return Uint8List.fromList(out);
}

// --- deterministic sample payloads -----------------------------------------

Uint8List get _tiny => Uint8List.fromList('hello bzip2 world\n'.codeUnits);
Uint8List get _text => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 2000).codeUnits,
);
Uint8List get _periodicSmall => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 8).codeUnits,
);
Uint8List get _runs => Uint8List.fromList(List.filled(5000, 0x41));
Uint8List get _ramp =>
    Uint8List.fromList(List.generate(20000, (i) => i & 0xFF));
Uint8List get _random {
  var x = 123456789;
  return Uint8List.fromList(
    List.generate(50000, (_) {
      x = (1103515245 * x + 12345) & 0x7FFFFFFF;
      return x & 0xFF;
    }),
  );
}

/// Two full blocks + a tail, to exercise the multi-block path and the
/// combined-CRC rotate. `blockSize100k: 1` caps a block at 100 000 bytes.
Uint8List get _multiBlock => Uint8List.fromList(
  List.generate(260000, (i) => (i * 7 + (i >> 3)) & 0xFF),
);

/// ~700 KB: at the default level 9 this is a single ~720 KB BWT block with a
/// high selector count, and it compresses well (long runs + structure).
Uint8List get _largeBlock {
  var x = 2246822519;
  return Uint8List.fromList(
    List.generate(700000, (i) {
      x = (1664525 * x + 1013904223) & 0xFFFFFFFF;
      // Mostly a small, structured alphabet with occasional noise bytes.
      return i % 5 == 0 ? (x >> 16) & 0xFF : 'koni'.codeUnitAt(i % 4);
    }),
  );
}

void main() {
  final cases = <String, Uint8List>{
    'empty': Uint8List(0),
    'single byte': Uint8List.fromList([0x2A]),
    'tiny text': _tiny,
    'repetitive text': _text,
    'small periodic (identical BWT rotations)': _periodicSmall,
    'a long run': _runs,
    'byte ramp': _ramp,
    'incompressible random': _random,
  };

  group('round trips through our own decoder', () {
    cases.forEach((name, data) {
      test(name, () => expect(_roundTrip(data), data));
    });

    test('multi-block at blockSize100k: 1', () {
      expect(_roundTrip(_multiBlock, blockSize100k: 1), _multiBlock);
    });

    test('a large single level-9 block (~700 KB)', () {
      expect(_roundTrip(_largeBlock), _largeBlock);
    });

    test('the RLE1 buffer boundary (inputs around 240–320 bytes)', () {
      // Regression: the RLE1 scratch buffer flushed at ~256 bytes; a copy-free
      // builder aliased and corrupted already-flushed slices past that point.
      for (var n = 240; n <= 320; n++) {
        final data = Uint8List.fromList(
          List.generate(n, (i) => 'abcdef'.codeUnitAt(i % 6)),
        );
        expect(_roundTrip(data), data, reason: 'n=$n');
      }
    });
  });

  group('output is decodable by the real bzip2', () {
    cases.forEach((name, data) {
      test(name, () async {
        final decoded = await _bzip2Decode(_encode(data));
        if (decoded == null) {
          markTestSkipped('bzip2 binary not available');
          return;
        }
        expect(decoded, data);
      });
    });

    test('multi-block at blockSize100k: 1', () async {
      final decoded =
          await _bzip2Decode(_encode(_multiBlock, blockSize100k: 1));
      if (decoded == null) {
        markTestSkipped('bzip2 binary not available');
        return;
      }
      expect(decoded, _multiBlock);
    });

    test('a large single level-9 block (~700 KB)', () async {
      final decoded = await _bzip2Decode(_encode(_largeBlock));
      if (decoded == null) {
        markTestSkipped('bzip2 binary not available');
        return;
      }
      expect(decoded, _largeBlock);
    });
  });

  test('every block size level 1..9 round-trips', () {
    for (var level = 1; level <= 9; level++) {
      expect(_roundTrip(_text, blockSize100k: level), _text, reason: 'L$level');
    }
  });

  test('rejects an out-of-range block size', () {
    expect(() => Bzip2Encoder(blockSize100k: 0), throwsArgumentError);
    expect(() => Bzip2Encoder(blockSize100k: 10), throwsArgumentError);
  });

  test('empty input is a valid, distinct stream', () {
    final empty = _encode(Uint8List(0));
    expect(empty.length, greaterThanOrEqualTo(4));
    // "BZh9" header, then the end-of-stream marker.
    expect(empty.sublist(0, 4), 'BZh9'.codeUnits);
  });

  test(
    'fuzz: random payloads round-trip and stay bzip2-compatible',
    () async {
      final seed = DateTime.now().millisecondsSinceEpoch;
      final random = Random(seed);
      printOnFailure('fuzz seed: $seed');
      final deadline = DateTime.now().add(
        Duration(
          seconds:
              int.tryParse(
                Platform.environment['KONI_ARCHIVE_FUZZ_SECONDS'] ?? '',
              ) ??
              4,
        ),
      );
      var bzipChecked = false;
      var iters = 0;
      while (DateTime.now().isBefore(deadline)) {
        iters++;
        final n = random.nextInt(2000);
        final data = Uint8List.fromList(
          List.generate(n, (_) {
            // Bias toward a small alphabet so runs and repeats occur.
            final r = random.nextInt(10);
            return r < 6 ? random.nextInt(4) : random.nextInt(256);
          }),
        );
        expect(_roundTrip(data), data, reason: 'own decoder, n=$n');
        if (!bzipChecked) {
          final decoded = await _bzip2Decode(_encode(data));
          if (decoded != null) {
            expect(decoded, data, reason: 'bzip2 -d, n=$n');
            bzipChecked = true; // one interop spawn is enough per run
          }
        }
      }
      printOnFailure('completed $iters iterations');
    },
    tags: ['fuzz'],
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
