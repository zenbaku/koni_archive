// Web-runnable RAR4 (RarVM) standard-filter decoding. Each fixture is a real
// rar 6.24 `-ma4 -m5` archive whose payload trips one of RAR's standard
// filters (delta, x86 E8, RGB, audio). The bytes are inlined as base64 (no
// dart:io) so the filter arithmetic runs on dart2js and dart2wasm, not just
// the VM. Reading verifies CRC-32 by default, so a decode that completes is
// byte-identical to the original the compressor saw -- a real end-to-end
// check against genuine RAR output, not a self-comparison.
//
// The same archives live in `test/fixtures/rar_static/filter_*.rar` for the
// fuzz smoke test; see that directory's README for provenance. The manga
// corpus additionally exercises the delta filter across 37 real pages.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:koni_rar/src/rar4_filters.dart' show debugForceRar4Vm;
import 'package:test/test.dart';

// filter_delta.rar -> delta filter (kind 0).
final _delta = base64.decode(
  'UmFyIRoHAM+QcwAADQAAAAAAAAC8SHQgkC0ARwEAADZsAAADNh1qTJii71wdNQgApIEAAGdyYWQu'
  'Ym1wALDBHSUAv4hf2un/u2HQAJsAAIaOl4DNIMB2E6QXhLs26fUgrayidAuucLZIpicfu4AEDREB'
  'C+TL0OMEQAqBJejBJkhUQm6SFhfyE7aNsxSYg8o6nkFuVZ42x8b64dz1p/+/bM3zAfNfMBRNfMBR'
  'NfMBRNfMBRNfMBRNfMBRNfMBR5AQ0RAL5Mi8QIkhFjaEWJIRRhk5AF/3FXagIgtS0QctiDlXPGnW'
  '/2gO9mun/Xl8xGa+YmM18xMZr5iYzXzExmvmJjNfMTGa+YmPYBDRVAk+DLuQ3InlKUiqFwJsMnjM'
  'LC/9xV7UBEFqimZKdo1ByrzP2//v4+/NtP3Vx7drfMTzXzERmvmIjNfMRGa+YiM18xEZr5iIzXzE'
  'RzAIFADL4VCv8HRERERN8N6bbnr+HAnkV0L7GeDfR3w/8ggiokwm4pArItQvYxgybNLEPXsAQAcA',
);

// filter_e8.rar -> x86 E8 filter (kind 1).
final _e8 = base64.decode(
  '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'
  '6QPYk7d/aMQ9ewBABwA=',
);

// filter_rgb.rar -> RGB filter (kind 3) plus a delta block.
final _rgb = base64.decode(
  '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'
  '7xn7fYObKL6TjVDEPXsAQAcA',
);

// filter_audio.rar -> audio filter (kind 4).
final _audio = base64.decode(
  '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',
);

/// Opens an in-memory RAR archive with checksum verification on (the default),
/// reads its single entry to completion, and returns the byte count read. A
/// CRC mismatch (wrong filter output) throws before this returns.
Future<int> _readOnly(Uint8List archive, String expectedName) async {
  final reader = await const RarFormat().openReader(
    MemoryByteSource(archive),
    const ArchiveReadOptions(),
  );
  final files = reader.entries.where((e) => !e.isDirectory).toList();
  expect(files, hasLength(1));
  expect(files.single.path, expectedName);
  var total = 0;
  await for (final chunk in reader.openRead(files.single)) {
    total += chunk.length;
  }
  await reader.close();
  return total;
}

void main() {
  test('decodes a RAR4 entry using the delta filter', () async {
    expect(await _readOnly(_delta, 'grad.bmp'), 27702);
  });

  test('decodes a RAR4 entry using the x86 (E8) filter', () async {
    expect(await _readOnly(_e8, 'x86call.bin'), 12016);
  });

  test('decodes a RAR4 entry using the RGB filter', () async {
    expect(await _readOnly(_rgb, 'rgbimg.bmp'), 61494);
  });

  test('decodes a RAR4 entry using the audio filter', () async {
    expect(await _readOnly(_audio, 'a_audio.raw'), 9600);
  });

  // The four standard programs are real RarVM bytecode. Forcing them through
  // the generic interpreter (instead of the native fast path) and getting the
  // same CRC-verified bytes proves the VM byte-exact — transitively vs `unrar`,
  // since these fixtures already pass against it. This is R6's core check
  // (modern rar can't author a non-standard program, so the standard ones are
  // the only VM oracle). Runs on dart2js/dart2wasm too.
  group('generic RarVM executes the standard programs byte-exact', () {
    setUp(() => debugForceRar4Vm = true);
    tearDown(() => debugForceRar4Vm = false);

    test('delta program on the VM', () async {
      expect(await _readOnly(_delta, 'grad.bmp'), 27702);
    });
    test('x86 E8 program on the VM', () async {
      expect(await _readOnly(_e8, 'x86call.bin'), 12016);
    });
    test('RGB (+ delta) program on the VM', () async {
      // Two chained filters in one file — exercises the VM's fresh-memory and
      // chaining paths, not just a single invocation.
      expect(await _readOnly(_rgb, 'rgbimg.bmp'), 61494);
    });
    test('audio program on the VM', () async {
      expect(await _readOnly(_audio, 'a_audio.raw'), 9600);
    });
  });
}
