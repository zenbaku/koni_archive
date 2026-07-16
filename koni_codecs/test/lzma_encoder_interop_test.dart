@TestOn('vm')
@Tags(['interop'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// Interop is the definition of done (per koni_sevenz/doc/writing-scope.md,
/// P2-4b gate 1): our LZMA output must decode under liblzma (via CPython's
/// `lzma` module) not just under our own decoder. The stream is framed as
/// `.lzma` (FORMAT_ALONE: props byte, u32 dict size, u64 uncompressed size),
/// which carries everything liblzma needs. Skipped (marked) when `python3`
/// is absent, so environments without it stay green.
void main() {
  final python = _findPython();

  Future<Uint8List> liblzmaDecode(Uint8List alone) async {
    final process = await Process.start(python!, [
      '-c',
      'import sys, lzma; '
          'sys.stdout.buffer.write(lzma.decompress('
          'sys.stdin.buffer.read(), format=lzma.FORMAT_ALONE))',
    ]);
    process.stdin.add(alone);
    await process.stdin.close();
    final out = <int>[];
    final err = <int>[];
    await Future.wait([
      process.stdout.forEach(out.addAll),
      process.stderr.forEach(err.addAll),
    ]);
    final exitCode = await process.exitCode;
    expect(
      exitCode,
      0,
      reason: 'liblzma rejected our stream: ${String.fromCharCodes(err)}',
    );
    return Uint8List.fromList(out);
  }

  final payloads = <String, Uint8List Function()>{
    'ascii text':
        () => Uint8List.fromList(
          ('the quick brown fox, lzma edition. ' * 250).codeUnits,
        ),
    'random bytes': () {
      final random = Random(1234);
      return Uint8List.fromList(
        List.generate(50000, (_) => random.nextInt(256)),
      );
    },
    'all zeros': () => Uint8List(100000),
    'byte structure':
        () => Uint8List.fromList(
          List.generate(65536, (i) => ((i * 3) ^ (i >> 5)) & 0xFF),
        ),
    'single byte': () => Uint8List.fromList([0]),
  };

  for (final MapEntry(key: name, value: build) in payloads.entries) {
    test('liblzma decodes our LZMA1 stream: $name', () async {
      if (python == null) {
        markTestSkipped('no `python3` on PATH; liblzma interop skipped');
        return;
      }
      final payload = build();
      final encoder = LzmaEncoder();
      final stream = encoder.encode(payload);
      expect(
        await liblzmaDecode(_aloneFrame(encoder, payload.length, stream)),
        payload,
      );
    });
  }

  test('liblzma decodes rep-heavy interleaved records', () async {
    if (python == null) {
      markTestSkipped('no `python3` on PATH; liblzma interop skipped');
      return;
    }
    final b = BytesBuilder(copy: false);
    final records = [
      'alpha-record: 0000|'.codeUnits,
      'beta-rec: 11111111|'.codeUnits,
      'gamma: 222|'.codeUnits,
      'delta-item: 33333|'.codeUnits,
    ];
    final random = Random(7);
    for (var i = 0; i < 3000; i++) {
      b.add(records[random.nextInt(4)]);
    }
    final payload = b.takeBytes();
    final encoder = LzmaEncoder();
    final stream = encoder.encode(payload);
    expect(
      await liblzmaDecode(_aloneFrame(encoder, payload.length, stream)),
      payload,
    );
  });

  test('liblzma decodes seeded fuzz payloads (tiny alphabet)', () async {
    if (python == null) {
      markTestSkipped('no `python3` on PATH; liblzma interop skipped');
      return;
    }
    final random = Random(31337);
    for (var i = 0; i < 20; i++) {
      final length = 1 + random.nextInt(5000);
      final payload = Uint8List.fromList(
        List.generate(length, (_) => 0x61 + random.nextInt(4)),
      );
      final encoder = LzmaEncoder();
      final stream = encoder.encode(payload);
      expect(
        await liblzmaDecode(_aloneFrame(encoder, payload.length, stream)),
        payload,
        reason: 'fuzz iteration $i (length $length)',
      );
    }
  });

  test('liblzma enforces our declared dictionary size', () async {
    // liblzma rejects any match distance beyond the header's dict size, so
    // this fails loudly if the finder's distance cap leaks: repeats sit
    // 8000 bytes apart while the declared dictionary is 4096.
    if (python == null) {
      markTestSkipped('no `python3` on PATH; liblzma interop skipped');
      return;
    }
    final random = Random(5);
    final block = Uint8List.fromList(
      List.generate(600, (_) => random.nextInt(256)),
    );
    final filler = Uint8List.fromList(
      List.generate(8000, (_) => random.nextInt(256)),
    );
    final payload = Uint8List.fromList([...block, ...filler, ...block]);
    final encoder = LzmaEncoder(dictSize: 4096);
    final stream = encoder.encode(payload);
    expect(
      await liblzmaDecode(_aloneFrame(encoder, payload.length, stream)),
      payload,
    );
  });

  Future<Uint8List> liblzmaDecodeRaw2(Uint8List stream, int dictSize) async {
    final process = await Process.start(python!, [
      '-c',
      'import sys, lzma; '
          'sys.stdout.buffer.write(lzma.decompress('
          'sys.stdin.buffer.read(), format=lzma.FORMAT_RAW, '
          'filters=[{"id": lzma.FILTER_LZMA2, "dict_size": $dictSize}]))',
    ]);
    process.stdin.add(stream);
    await process.stdin.close();
    final out = <int>[];
    final err = <int>[];
    await Future.wait([
      process.stdout.forEach(out.addAll),
      process.stderr.forEach(err.addAll),
    ]);
    final exitCode = await process.exitCode;
    expect(
      exitCode,
      0,
      reason: 'liblzma rejected our LZMA2 stream: ${String.fromCharCodes(err)}',
    );
    return Uint8List.fromList(out);
  }

  test('liblzma decodes our LZMA2 stream (text, many small chunks)', () async {
    if (python == null) {
      markTestSkipped('no `python3` on PATH; liblzma interop skipped');
      return;
    }
    final payload = Uint8List.fromList(
      ('chunked lzma2 for the seven-zip writer. ' * 2000).codeUnits,
    );
    final encoder = Lzma2Encoder(chunkSize: 1 << 13);
    final stream = encoder.encode(payload);
    expect(await liblzmaDecodeRaw2(stream, 1 << 23), payload);
  });

  test('liblzma decodes our LZMA2 fallback + reset transitions', () async {
    if (python == null) {
      markTestSkipped('no `python3` on PATH; liblzma interop skipped');
      return;
    }
    final random = Random(23);
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < 6; i++) {
      b.add(('segment $i: compressible prose. ' * 400).codeUnits);
      b.add(List.generate(30000, (_) => random.nextInt(256)));
    }
    final payload = b.takeBytes();
    final encoder = Lzma2Encoder(chunkSize: 1 << 14);
    final stream = encoder.encode(payload);
    expect(await liblzmaDecodeRaw2(stream, 1 << 23), payload);
  });

  test('liblzma decodes an empty LZMA2 stream', () async {
    if (python == null) {
      markTestSkipped('no `python3` on PATH; liblzma interop skipped');
      return;
    }
    final stream = Lzma2Encoder().encode(Uint8List(0));
    expect(await liblzmaDecodeRaw2(stream, 1 << 23), isEmpty);
  });

  test('liblzma decodes a default-chunk-size multi-chunk stream', () async {
    // > 2 MiB of compressible data: at least two full-size (~2 MiB)
    // compressed chunks through the default path.
    if (python == null) {
      markTestSkipped('no `python3` on PATH; liblzma interop skipped');
      return;
    }
    final random = Random(55);
    const words = ['lorem', 'ipsum', 'dolor', 'sit', 'amet', 'koni'];
    final b = BytesBuilder(copy: false);
    while (b.length < 5 * 1024 * 1024) {
      b.add(words[random.nextInt(words.length)].codeUnits);
      b.addByte(0x20);
    }
    final payload = b.takeBytes();
    final encoder = Lzma2Encoder();
    final stream = encoder.encode(payload);
    expect(await liblzmaDecodeRaw2(stream, 1 << 23), payload);
  });

  test('liblzma decodes non-default properties (lc=0 lp=2 pb=1)', () async {
    if (python == null) {
      markTestSkipped('no `python3` on PATH; liblzma interop skipped');
      return;
    }
    final payload = Uint8List.fromList(('property soup ' * 500).codeUnits);
    final encoder = LzmaEncoder(lc: 0, lp: 2, pb: 1);
    final stream = encoder.encode(payload);
    expect(
      await liblzmaDecode(_aloneFrame(encoder, payload.length, stream)),
      payload,
    );
  });
}

/// Frames a raw LZMA stream as `.lzma` (FORMAT_ALONE): 13-byte header of
/// props byte, little-endian u32 dictionary size, little-endian u64
/// uncompressed size.
Uint8List _aloneFrame(
  LzmaEncoder encoder,
  int uncompressedSize,
  Uint8List stream,
) {
  final header = Uint8List(13);
  header.setAll(0, encoder.sevenZipProps());
  var size = uncompressedSize;
  for (var i = 5; i < 13; i++) {
    header[i] = size % 256;
    size = size ~/ 256;
  }
  return Uint8List.fromList([...header, ...stream]);
}

String? _findPython() {
  for (final candidate in [
    '/opt/homebrew/bin/python3',
    '/usr/local/bin/python3',
    '/usr/bin/python3',
    'python3',
  ]) {
    try {
      final r = Process.runSync(candidate, ['-c', 'import lzma']);
      if (r.exitCode == 0) return candidate;
    } on ProcessException {
      continue;
    }
  }
  return null;
}
