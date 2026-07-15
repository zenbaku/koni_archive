import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

import 'src/lzma_vectors.dart';

Uint8List _b64(String s) => base64.decode(s);

Uint8List _payload1() {
  final builder = BytesBuilder(copy: false);
  for (var i = 0; i < 150; i++) {
    builder.add(utf8.encode('hello, lzma! '));
  }
  for (var i = 0; i < 4; i++) {
    builder.add(Uint8List.fromList(List.generate(256, (j) => j)));
  }
  return builder.takeBytes();
}

Uint8List _payload2() =>
    utf8.encode('the quick brown fox jumps over the lazy dog. ' * 200);

Uint8List _payload4() =>
    Uint8List.fromList(List.generate(4096, (i) => ((i * 3) ^ (i >> 2)) & 0xFF));

void main() {
  group('LZMA1 (liblzma FORMAT_ALONE vector)', () {
    test('decodes the reference stream', () {
      final alone = _b64(lzmaAloneBase64);
      final payload = _payload1();
      // .lzma header: props byte, 4-byte dict size, 8-byte size.
      final output = Uint8List(payload.length);
      final decoder = LzmaDecoder(output: output)..setProps(alone[0]);
      decoder.addInput(Uint8List.sublistView(alone, 13));
      decoder.setInputComplete();
      expect(decoder.isChunkComplete, isTrue);
      expect(output, payload);
    });

    test('chunk boundaries never matter (§6.4)', () {
      final alone = _b64(lzmaAloneBase64);
      final payload = _payload1();
      for (final chunkSize in [1, 3, 17, 64]) {
        final output = Uint8List(payload.length);
        final decoder = LzmaDecoder(output: output)..setProps(alone[0]);
        for (var i = 13; i < alone.length; i += chunkSize) {
          final end =
              i + chunkSize < alone.length ? i + chunkSize : alone.length;
          decoder.addInput(Uint8List.sublistView(alone, i, end));
        }
        decoder.setInputComplete();
        expect(output, payload, reason: 'chunk size $chunkSize');
      }
    });

    test('truncation throws FormatException', () {
      final alone = _b64(lzmaAloneBase64);
      final output = Uint8List(_payload1().length);
      final decoder = LzmaDecoder(output: output)..setProps(alone[0]);
      decoder.addInput(Uint8List.sublistView(alone, 13, alone.length - 20));
      expect(decoder.setInputComplete, throwsFormatException);
    });

    test('corruption throws FormatException, never anything else', () {
      final alone = _b64(lzmaAloneBase64);
      final payload = _payload1();
      for (final flipAt in [20, 60, 150, alone.length - 5]) {
        final bad = Uint8List.fromList(alone);
        bad[flipAt] ^= 0x55;
        final output = Uint8List(payload.length);
        final decoder = LzmaDecoder(output: output)..setProps(bad[0]);
        Object? error;
        try {
          decoder.addInput(Uint8List.sublistView(bad, 13));
          decoder.setInputComplete();
          // Corruption may also decode to wrong bytes without erroring —
          // that is what container CRCs are for. No throw is acceptable.
        } on Object catch (e) {
          error = e;
        }
        expect(
          error,
          anyOf(isNull, isA<FormatException>()),
          reason: 'flip at $flipAt',
        );
      }
    });

    test('invalid properties byte is rejected', () {
      expect(
        () => LzmaDecoder(output: Uint8List(1)).setProps(225),
        throwsFormatException,
      );
    });
  });

  group('LZMA2 (liblzma FORMAT_RAW vectors)', () {
    test('decodes a compressed-chunk stream', () {
      final payload = _payload2();
      final output = Uint8List(payload.length);
      final decoder = Lzma2Decoder(output: output);
      decoder.addInput(_b64(lzma2Base64));
      decoder.finish();
      expect(decoder.isFinished, isTrue);
      expect(output, payload);
    });

    test('decodes uncompressed chunks (preset-0 incompressible data)', () {
      final payload = _b64(payload3Base64);
      final output = Uint8List(payload.length);
      final decoder = Lzma2Decoder(output: output);
      decoder.addInput(_b64(lzma2UncompressedBase64));
      decoder.finish();
      expect(output, payload);
    });

    test('chunk boundaries never matter (§6.4)', () {
      final payload = _b64(payload3Base64);
      final stream = _b64(lzma2UncompressedBase64);
      for (final chunkSize in [1, 7, 100]) {
        final output = Uint8List(payload.length);
        final decoder = Lzma2Decoder(output: output);
        for (var i = 0; i < stream.length; i += chunkSize) {
          final end =
              i + chunkSize < stream.length ? i + chunkSize : stream.length;
          decoder.addInput(Uint8List.sublistView(stream, i, end));
        }
        decoder.finish();
        expect(output, payload, reason: 'chunk size $chunkSize');
      }
    });

    test('truncation throws FormatException', () {
      final stream = _b64(lzma2Base64);
      final output = Uint8List(_payload2().length);
      final decoder = Lzma2Decoder(output: output);
      expect(() {
        decoder.addInput(Uint8List.sublistView(stream, 0, stream.length - 10));
        decoder.finish();
      }, throwsFormatException);
    });
  });

  group('filters (verified against liblzma pipelines)', () {
    test('delta decode reverses FILTER_DELTA', () {
      final payload = _payload4();
      final filtered = Uint8List(payload.length);
      final decoder = Lzma2Decoder(output: filtered);
      decoder.addInput(_b64(deltaLzma2Base64));
      decoder.finish();
      deltaDecode(filtered, 4);
      expect(filtered, payload);
    });

    test('x86 BCJ decode reverses FILTER_X86', () {
      final payload = _b64(payload5Base64);
      final filtered = Uint8List(payload.length);
      final decoder = Lzma2Decoder(output: filtered);
      decoder.addInput(_b64(x86Lzma2Base64));
      decoder.finish();
      bcjX86Decode(filtered);
      expect(filtered, payload);
    });

    test('delta rejects invalid distances', () {
      expect(() => deltaDecode(Uint8List(4), 0), throwsFormatException);
      expect(() => deltaDecode(Uint8List(4), 300), throwsFormatException);
    });

    test('bcj on tiny buffers is a no-op', () {
      final tiny = Uint8List.fromList([0xE8, 1, 2, 3]);
      bcjX86Decode(tiny);
      expect(tiny, [0xE8, 1, 2, 3]);
    });
  });
}
