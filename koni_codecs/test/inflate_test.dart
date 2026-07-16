import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

import 'src/vectors.dart';

/// Decodes with input split into pieces of [chunkSize] via the chunked
/// sink, the contract: byte boundaries never matter.
Uint8List _chunkedInflate(List<int> compressed, int chunkSize) {
  final out = BytesBuilder(copy: false);
  final collector = ByteConversionSink.withCallback((bytes) => out.add(bytes));
  final sink = const InflateDecoder().startChunkedConversion(collector);
  for (var i = 0; i < compressed.length; i += chunkSize) {
    final end = min(i + chunkSize, compressed.length);
    sink.add(compressed.sublist(i, end));
  }
  sink.close();
  return out.takeBytes();
}

void main() {
  group('reference vectors (CPython zlib)', () {
    test('fixed-Huffman block', () {
      expect(
        utf8.decode(const InflateDecoder().convert(helloWorldDeflate)),
        helloWorldPlain,
      );
    });

    test('empty stream', () {
      expect(const InflateDecoder().convert(emptyDeflate), isEmpty);
    });

    test('dynamic Huffman with matches', () {
      expect(
        utf8.decode(const InflateDecoder().convert(repetitiveDeflate)),
        repetitivePlain,
      );
    });

    test('stored block', () {
      expect(const InflateDecoder().convert(storedDeflate), storedPlain);
    });

    test('single byte', () {
      expect(const InflateDecoder().convert(singleDeflate), [0x78]);
    });
  });

  group('chunk boundaries never matter', () {
    for (final chunkSize in [1, 2, 3, 7, 64]) {
      test('dynamic vector in $chunkSize-byte chunks', () {
        expect(
          utf8.decode(_chunkedInflate(repetitiveDeflate, chunkSize)),
          repetitivePlain,
        );
      });
      test('stored vector in $chunkSize-byte chunks', () {
        expect(_chunkedInflate(storedDeflate, chunkSize), storedPlain);
      });
    }
  });

  group('malformed input throws FormatException', () {
    test('invalid block type 3', () {
      // BFINAL=1, BTYPE=11.
      expect(
        () => const InflateDecoder().convert([0x07]),
        throwsFormatException,
      );
    });

    test('truncation at every prefix of a valid stream', () {
      for (var cut = 0; cut < repetitiveDeflate.length; cut++) {
        expect(
          () =>
              const InflateDecoder().convert(repetitiveDeflate.sublist(0, cut)),
          throwsFormatException,
          reason: 'cut at $cut',
        );
      }
    });

    test('stored block with corrupted NLEN', () {
      final corrupted = [...storedDeflate];
      corrupted[3] ^= 0xFF; // NLEN no longer ~LEN
      expect(
        () => const InflateDecoder().convert(corrupted),
        throwsFormatException,
      );
    });

    test('trailing data after the final block', () {
      expect(
        () => const InflateDecoder().convert([...emptyDeflate, 0xAA, 0xBB]),
        throwsFormatException,
      );
    });

    test('match distance before the start of output', () {
      // Fixed-Huffman block whose first symbol is a match: nothing to copy
      // from. BFINAL=1 BTYPE=01, then length code 257 (7-bit code 0000001),
      // distance code 0 (5-bit code 00000, distance 1).
      final writer = _BitWriter();
      writer.bits(1, 1); // BFINAL
      writer.bits(1, 2); // BTYPE fixed
      writer.bitsMsb(1, 7); // symbol 257 -> length 3
      writer.bitsMsb(0, 5); // distance 1, but no output yet
      writer.bitsMsb(0, 7); // end of block
      expect(
        () => const InflateDecoder().convert(writer.finish()),
        throwsFormatException,
      );
    });

    test('oversubscribed dynamic Huffman table', () {
      // HLIT=257, HDIST=1, HCLEN=19; all code-length codes get length 1.
      // 19 codes of length 1 is grossly oversubscribed.
      final writer = _BitWriter();
      writer.bits(1, 1); // BFINAL
      writer.bits(2, 2); // BTYPE dynamic
      writer.bits(0, 5); // HLIT
      writer.bits(0, 5); // HDIST
      writer.bits(15, 4); // HCLEN = 19
      for (var i = 0; i < 19; i++) {
        writer.bits(1, 3);
      }
      expect(
        () => const InflateDecoder().convert(writer.finish()),
        throwsFormatException,
      );
    });

    test('code-length repeat with no previous length', () {
      // Degenerate header where the first code-length symbol is 16
      // (repeat-previous), nothing to repeat.
      final writer = _BitWriter();
      writer.bits(1, 1);
      writer.bits(2, 2);
      writer.bits(0, 5);
      writer.bits(0, 5);
      writer.bits(0, 4); // HCLEN = 4 -> order 16,17,18,0
      writer.bits(1, 3); // len(16) = 1
      writer.bits(0, 3); // len(17) = 0
      writer.bits(0, 3); // len(18) = 0
      writer.bits(1, 3); // len(0) = 1
      // Canonical (same length, ascending symbol): 0 -> code 0, 16 -> code 1.
      writer.bits(1, 1); // symbol 16 immediately
      writer.bits(0, 2); // repeat count bits
      expect(
        () => const InflateDecoder().convert(writer.finish()),
        throwsFormatException,
      );
    });
  });

  group('degenerate-but-legal streams', () {
    test('fixed-Huffman literal + overlapping match', () {
      // Literal 'a', then a length-9 match at distance 1 (classic
      // overlapping copy), end of block: 'aaaaaaaaaa'.
      final writer = _BitWriter();
      writer.bits(1, 1); // BFINAL
      writer.bits(1, 2); // fixed
      writer.bitsMsb(0x30 + 0x61, 8); // literal 'a' (code 0x30+97, 8 bits)
      writer.bitsMsb(0x07, 7); // length code 263 (len 9): 0000111
      writer.bitsMsb(0, 5); // distance code 0 = distance 1
      writer.bitsMsb(0, 7); // end of block
      expect(
        utf8.decode(const InflateDecoder().convert(writer.finish())),
        'aaaaaaaaaa',
      );
    });

    test('dynamic block with a single-code (incomplete) distance tree', () {
      // Degenerate dynamic Huffman (canonical edge case):
      //   literal tree: 'a' and 256, one bit each (complete);
      //   distance tree: one symbol with a 1-bit code, INCOMPLETE, which
      //   RFC 1951 explicitly allows for single-code distance trees.
      final writer = _BitWriter();
      writer.bits(1, 1); // BFINAL
      writer.bits(2, 2); // dynamic
      writer.bits(0, 5); // HLIT  = 257
      writer.bits(0, 5); // HDIST = 1
      writer.bits(14, 4); // HCLEN = 18 (through order index of symbol 1)
      // Code-length code lengths, transmission order
      // 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1(,15):
      for (final length in [
        0,
        2,
        2,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        2,
      ]) {
        writer.bits(length, 3);
      }
      // CL canonical codes (all length 2, ascending symbol):
      // 0 -> 00, 1 -> 01, 17 -> 10, 18 -> 11.
      void clZero18(int count) {
        writer.bitsMsb(3, 2); // symbol 18
        writer.bits(count - 11, 7);
      }

      void clZero17(int count) {
        writer.bitsMsb(2, 2); // symbol 17
        writer.bits(count - 3, 3);
      }

      void clOne() => writer.bitsMsb(1, 2); // symbol 1

      clZero18(88); // lengths 0..87   = 0
      clZero17(9); //  lengths 88..96  = 0
      clOne(); //      length  97 ('a') = 1
      clZero18(138); // lengths 98..235 = 0
      clZero18(20); //  lengths 236..255 = 0
      clOne(); //      length 256       = 1
      clOne(); //      distance symbol 0 = 1  (single-code, incomplete)
      // Literal tree canonical: 'a' -> 0, 256 -> 1.
      writer.bitsMsb(0, 1); // 'a'
      writer.bitsMsb(1, 1); // end of block
      expect(utf8.decode(const InflateDecoder().convert(writer.finish())), 'a');
    });

    test('RawInflater reports leftover bytes past the stream end', () {
      final inflater = RawInflater(onOutput: (_) {});
      final input = Uint8List.fromList([...emptyDeflate, 0xDE, 0xAD]);
      final consumed = inflater.addInput(input);
      expect(inflater.isFinished, isTrue);
      final leftovers = inflater.takeLeftoverBytes();
      // consumed + leftovers must account for exactly the trailing 2 bytes.
      expect(input.length - consumed + leftovers.length, 2);
    });
  });
}

/// LSB-first bit writer for hand-rolled deflate streams.
final class _BitWriter {
  final List<int> _bytes = [];
  int _buf = 0;
  int _count = 0;

  /// Writes [count] bits of [value], LSB-first (header/extra fields).
  void bits(int value, int count) {
    for (var i = 0; i < count; i++) {
      _buf |= ((value >> i) & 1) << _count;
      if (++_count == 8) {
        _bytes.add(_buf);
        _buf = 0;
        _count = 0;
      }
    }
  }

  /// Writes a Huffman code: [count] bits of [value] MSB-first (RFC 1951
  /// packs code bits most-significant first).
  void bitsMsb(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      bits((value >> i) & 1, 1);
    }
  }

  Uint8List finish() {
    if (_count > 0) {
      _bytes.add(_buf);
      _buf = 0;
      _count = 0;
    }
    return Uint8List.fromList(_bytes);
  }
}
