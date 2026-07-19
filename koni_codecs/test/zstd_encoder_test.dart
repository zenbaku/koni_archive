@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

Uint8List _encode(Uint8List data) => ZstdEncoder().encode(data);
Uint8List _roundTrip(Uint8List data) =>
    const ZstdDecoder().convert(_encode(data));

/// Decodes [zst] with the real `zstd` binary, or null when it is unavailable.
Future<Uint8List?> _zstdDecode(Uint8List zst) async {
  try {
    await Process.run('zstd', ['--version']);
  } on ProcessException {
    return null;
  }
  final proc = await Process.start('zstd', ['-dc']);
  proc.stdin.add(zst);
  await proc.stdin.close();
  final out = <int>[];
  final collect = proc.stdout.forEach(out.addAll);
  final err = await proc.stderr.transform(systemEncoding.decoder).join();
  await collect;
  final code = await proc.exitCode;
  if (code != 0) fail('zstd -d failed (exit $code): $err');
  return Uint8List.fromList(out);
}

// --- deterministic sample payloads -----------------------------------------

Uint8List get _tiny => Uint8List.fromList('hello zstd world\n'.codeUnits);
Uint8List get _text => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 2000).codeUnits,
);
Uint8List get _runs => Uint8List.fromList(List.filled(10000, 0x41));
Uint8List get _zeros => Uint8List(50000);
Uint8List get _ramp =>
    Uint8List.fromList(List.generate(40000, (i) => i & 0xFF));
Uint8List get _mixed => Uint8List.fromList([
  ...('lorem ipsum dolor sit amet ' * 300).codeUnits,
  ...List.filled(3000, 0x2A),
  ...('consectetur adipiscing elit ' * 250).codeUnits,
]);
Uint8List get _trueRandom {
  final r = Random(20260718);
  return Uint8List.fromList(List.generate(30000, (_) => r.nextInt(256)));
}

/// Skewed 7-bit ASCII with little repeat structure: literal-heavy, so Huffman
/// literal coding (rather than matches) does the work.
Uint8List _skewedAscii(int n) {
  final r = Random(99);
  return Uint8List.fromList(
    List.generate(n, (_) {
      final v = r.nextInt(100);
      return v < 45
          ? 97
          : v < 70
          ? 101
          : v < 84
          ? 116
          : v < 92
          ? 111
          : 98 + (v % 24);
    }),
  );
}

/// High-byte alphabet (values > 128): direct-weight Huffman can't encode the
/// table, so the encoder must fall back to raw literals without corrupting.
Uint8List _highByte(int n) {
  final r = Random(7);
  return Uint8List.fromList(List.generate(n, (_) => 129 + r.nextInt(127)));
}

/// Larger than one 128 KiB block, to exercise the multi-block path with
/// cross-block back-references.
Uint8List get _multiBlock => Uint8List.fromList(
  List.generate(
    400000,
    (i) => (i % 1000 < 620) ? 97 + (i % 7) : (i * 13) & 0xFF,
  ),
);

void main() {
  final cases = <String, Uint8List>{
    'empty': Uint8List(0),
    'single byte': Uint8List.fromList([0x2A]),
    'tiny': _tiny,
    'repetitive text': _text,
    'a long run': _runs,
    'all zeros': _zeros,
    'byte ramp': _ramp,
    'mixed literals + matches': _mixed,
    'incompressible random': _trueRandom,
    'multi-block': _multiBlock,
    'skewed ascii (huffman literals)': _skewedAscii(30000),
    'skewed ascii, single stream': _skewedAscii(700),
    'skewed ascii, sizeFormat-3 block': _skewedAscii(120000),
    'high-byte literals (raw fallback)': _highByte(20000),
  };

  group('round trips through our own decoder', () {
    cases.forEach((name, data) {
      test(name, () => expect(_roundTrip(data), data));
    });

    test('inputs around the block boundary (131060..131080 bytes)', () {
      for (var n = 131060; n <= 131080; n++) {
        final data = Uint8List.fromList(
          List.generate(n, (i) => 'abcdefgh'.codeUnitAt(i % 8)),
        );
        expect(_roundTrip(data), data, reason: 'n=$n');
      }
    });
  });

  group('output is decodable by the real zstd', () {
    cases.forEach((name, data) {
      test(name, () async {
        final decoded = await _zstdDecode(_encode(data));
        if (decoded == null) {
          markTestSkipped('zstd binary not available');
          return;
        }
        expect(decoded, data);
      });
    });
  });

  test('compresses repetitive input well', () {
    final enc = _encode(_text);
    expect(enc.length, lessThan(_text.length ~/ 20));
  });

  test('Huffman literals compress skewed literal-heavy input', () {
    // Raw literals would give ~1.0; entropy coding should beat 0.75 here.
    final data = _skewedAscii(40000);
    final enc = _encode(data);
    expect(enc.length, lessThan((data.length * 3) ~/ 4));
  });

  test('literal-heavy ratio does not degrade as input grows (regression)', () {
    // The greedy min-3 match finder emitted coincidental short matches at far
    // offsets that fragmented the literal runs and hurt Huffman coding, so the
    // ratio *rose* with size (~0.79 -> 0.83 -> 0.85 at 10k/50k/200k). The
    // net-cost match gate rejects those, so the ratio must now stay flat or
    // improve as the same distribution grows. Guards the exact bug the gate
    // fixes; the same input distribution keeps this comparison meaningful.
    double ratio(int n) {
      final data = _skewedAscii(n);
      return _encode(data).length / data.length;
    }

    final r10k = ratio(10000);
    final r50k = ratio(50000);
    final r200k = ratio(200000);
    expect(r50k, lessThanOrEqualTo(r10k), reason: '50k=$r50k > 10k=$r10k');
    expect(r200k, lessThanOrEqualTo(r10k), reason: '200k=$r200k > 10k=$r10k');
    // The pre-fix encoder produced ~0.85 at 200k; a comfortable ceiling here.
    expect(r200k, lessThan(0.72), reason: 'ratio at 200k = $r200k');
  });

  test('high-byte alphabet falls back to raw without expanding much', () {
    final data = _highByte(20000);
    final enc = _encode(data);
    expect(_roundTrip(data), data);
    expect(enc.length, lessThan(data.length + 200));
  });

  test('incompressible input stays close to its size (raw fallback)', () {
    final enc = _encode(_trueRandom);
    expect(enc.length, lessThan(_trueRandom.length + 200));
  });

  test('empty input is a valid frame', () {
    final enc = _encode(Uint8List(0));
    // Magic 0xFD2FB528 little-endian.
    expect(enc.sublist(0, 4), [0x28, 0xB5, 0x2F, 0xFD]);
    expect(const ZstdDecoder().convert(enc), isEmpty);
  });

  test('a 1 MiB input (well within the window) round-trips', () {
    final data = Uint8List(1 << 20); // zeros
    expect(_roundTrip(data), data);
  });

  test('an encoder instance is reusable across encode() calls', () {
    final enc = ZstdEncoder();
    // Different sizes and content, back to back on the same instance: the
    // match-finder state must reset each call (no stale positions / RangeError).
    final a = _text; // large
    final b = _tiny; // then smaller
    final c = _multiBlock; // then larger again
    expect(const ZstdDecoder().convert(enc.encode(a)), a);
    expect(const ZstdDecoder().convert(enc.encode(b)), b);
    expect(const ZstdDecoder().convert(enc.encode(c)), c);
  });

  test(
    'fuzz: random payloads round-trip and stay zstd-compatible',
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
      var interopChecked = false;
      var iters = 0;
      while (DateTime.now().isBefore(deadline)) {
        iters++;
        final n = random.nextInt(5000);
        final data = Uint8List.fromList(
          List.generate(n, (_) {
            // Bias toward a small alphabet so matches and runs occur.
            final r = random.nextInt(10);
            return r < 6 ? random.nextInt(5) : random.nextInt(256);
          }),
        );
        expect(_roundTrip(data), data, reason: 'own decoder, n=$n');
        if (!interopChecked && n > 0) {
          final decoded = await _zstdDecode(_encode(data));
          if (decoded != null) {
            expect(decoded, data, reason: 'zstd -d, n=$n');
            interopChecked = true;
          }
        }
      }
      printOnFailure('completed $iters iterations');
    },
    tags: ['fuzz'],
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
