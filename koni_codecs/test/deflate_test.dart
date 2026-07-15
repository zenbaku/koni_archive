import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

Uint8List _deflate(List<int> data) => const DeflateEncoder().convert(data);

Uint8List _inflate(List<int> data) => const InflateDecoder().convert(data);

void main() {
  group('round-trips through our own inflate', () {
    final cases = <String, Uint8List>{
      'empty': Uint8List(0),
      'single byte': Uint8List.fromList([0x42]),
      'short text': Uint8List.fromList(utf8.encode('hello, deflate!')),
      'repetitive': Uint8List.fromList(
        utf8.encode('abcabcabc' * 100 + 'the quick brown fox ' * 50),
      ),
      'all same': Uint8List.fromList(List.filled(50000, 0x5A)),
      'counting': Uint8List.fromList(List.generate(70000, (i) => i & 0xFF)),
    };

    cases.forEach((name, data) {
      test('$name (${data.length} B)', () {
        final compressed = _deflate(data);
        expect(_inflate(compressed), data, reason: name);
      });
    });

    test('incompressible random data still round-trips', () {
      final random = Random(1);
      final data = Uint8List.fromList(
        List.generate(40000, (_) => random.nextInt(256)),
      );
      expect(_inflate(_deflate(data)), data);
    });

    test('data spanning many 32 KiB blocks', () {
      final data = Uint8List.fromList(
        List.generate(200000, (i) => ((i * 31) ^ (i >> 5)) & 0xFF),
      );
      expect(_inflate(_deflate(data)), data);
    });
  });

  group('compresses redundant data', () {
    test('a highly repetitive input shrinks substantially', () {
      final data = Uint8List.fromList(utf8.encode('koni ' * 5000));
      final compressed = _deflate(data);
      expect(compressed.length, lessThan(data.length ~/ 5));
      expect(_inflate(compressed), data);
    });
  });

  group('chunked encoding', () {
    test('splitting input into chunks yields decodable output', () {
      final data = Uint8List.fromList(utf8.encode('streaming ' * 4000));
      final out = BytesBuilder(copy: false);
      final sink = const DeflateEncoder().startChunkedConversion(
        ByteConversionSink.withCallback((bytes) => out.add(bytes)),
      );
      for (var i = 0; i < data.length; i += 777) {
        final end = min(i + 777, data.length);
        sink.add(data.sublist(i, end));
      }
      sink.close();
      expect(_inflate(out.takeBytes()), data);
    });
  });
}
