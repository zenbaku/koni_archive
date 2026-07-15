@TestOn('vm')
@Tags(['interop'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// Interop is the definition of done (per koni_sevenz/doc/writing-scope.md,
/// P2-4b gate 1): our LZMA output must decode under liblzma — via CPython's
/// `lzma` module — not just under our own decoder. The stream is framed as
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
    'ascii text': () =>
        Uint8List.fromList(('the quick brown fox, lzma edition. ' * 250).codeUnits),
    'random bytes': () {
      final random = Random(1234);
      return Uint8List.fromList(
        List.generate(50000, (_) => random.nextInt(256)),
      );
    },
    'all zeros': () => Uint8List(100000),
    'byte structure': () => Uint8List.fromList(
      List.generate(65536, (i) => ((i * 3) ^ (i >> 5)) & 0xFF),
    ),
    'single byte': () => Uint8List.fromList([0]),
  };

  for (final MapEntry(key: name, value: build) in payloads.entries) {
    test('liblzma decodes our LZMA1 stream — $name', () async {
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
Uint8List _aloneFrame(LzmaEncoder encoder, int uncompressedSize, Uint8List stream) {
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
