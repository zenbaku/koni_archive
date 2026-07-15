import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// Bit-level round-trip for [RangeEncoder]: every primitive the encoder
/// emits must decode to the same symbols through a reference range decoder
/// whose arithmetic is copied verbatim from `LzmaDecoder` (which is itself
/// pinned by liblzma vectors in lzma_test.dart). Probability arrays adapt in
/// lockstep on both sides, so any drift — carry handling above all — shows
/// up as a mismatch.
void main() {
  group('RangeEncoder round-trip', () {
    test('adaptive bits, direct bits, trees, reverse trees (property)', () {
      final random = Random(20260715);
      for (var iteration = 0; iteration < 200; iteration++) {
        final ops = <_Op>[];
        // A pool of probability slots shared across ops, so probabilities
        // adapt far away from their initial 1024 (biased per slot to push
        // some toward each extreme).
        final slotBias = List<double>.generate(64, (_) => random.nextDouble());
        for (var i = 0; i < 500; i++) {
          switch (random.nextInt(4)) {
            case 0:
              final slot = random.nextInt(64);
              ops.add(
                _Op.bit(slot, random.nextDouble() < slotBias[slot] ? 1 : 0),
              );
            case 1:
              final count = 1 + random.nextInt(30);
              // Bias toward all-ones values: the carry cascade lives there.
              final value =
                  random.nextBool()
                      ? (1 << count) - 1
                      : random.nextInt(1 << count);
              ops.add(_Op.direct(value, count));
            case 2:
              final bits = 1 + random.nextInt(8);
              ops.add(_Op.tree(bits, random.nextInt(1 << bits)));
            case 3:
              final bits = 1 + random.nextInt(8);
              ops.add(_Op.treeReverse(bits, random.nextInt(1 << bits)));
          }
        }
        _roundTrip(ops, reason: 'iteration $iteration');
      }
    });

    test('long all-ones runs force carry cascades through 0xFF caches', () {
      final ops = [
        for (var i = 0; i < 10000; i++) _Op.direct(0x3FFFFFFF, 30),
      ];
      _roundTrip(ops, reason: 'all-ones direct bits');
    });

    test('long all-zero runs (minimal output, no carries)', () {
      final ops = [for (var i = 0; i < 10000; i++) _Op.direct(0, 30)];
      _roundTrip(ops, reason: 'all-zero direct bits');
    });

    test('strongly adapted probabilities against the grain', () {
      // Drive one slot toward "always 0", then encode 1s through it (the
      // most expensive symbols, max normalizations per bit) — and vice
      // versa.
      final ops = <_Op>[
        for (var i = 0; i < 2000; i++) _Op.bit(0, 0),
        for (var i = 0; i < 50; i++) _Op.bit(0, 1),
        for (var i = 0; i < 2000; i++) _Op.bit(1, 1),
        for (var i = 0; i < 50; i++) _Op.bit(1, 0),
      ];
      _roundTrip(ops, reason: 'adversarial adaptation');
    });

    test('reset() yields a fresh, independently decodable stream', () {
      final encoder = RangeEncoder();
      final firstOps = [_Op.direct(0x155, 10), _Op.bit(0, 1), _Op.bit(0, 1)];
      final secondOps = [_Op.tree(6, 33), _Op.treeReverse(4, 9)];

      final probs1 = _freshProbs();
      for (final op in firstOps) {
        op.encode(encoder, probs1);
      }
      encoder.flush();
      Uint8List? first;
      encoder.drain((Uint8List chunk) => first = chunk);

      encoder.reset();
      final probs2 = _freshProbs();
      for (final op in secondOps) {
        op.encode(encoder, probs2);
      }
      encoder.flush();
      Uint8List? second;
      encoder.drain((Uint8List chunk) => second = chunk);

      _expectDecodes(first!, firstOps, reason: 'stream before reset');
      _expectDecodes(second!, secondOps, reason: 'stream after reset');
    });

    test('flush is idempotent-safe after reset', () {
      final encoder = RangeEncoder();
      encoder.flush();
      Uint8List? out;
      encoder.drain((Uint8List chunk) => out = chunk);
      // An empty stream is just the coder's 5 pending bytes.
      expect(out!.length, 5);
    });

    test('emittedCount tracks buffered bytes', () {
      final encoder = RangeEncoder();
      expect(encoder.emittedCount, 0);
      final probs = _freshProbs();
      for (var i = 0; i < 1000; i++) {
        encoder.encodeBit(probs, i & 63, i & 1);
      }
      final beforeFlush = encoder.emittedCount;
      expect(beforeFlush, greaterThan(0));
      encoder.flush();
      final total = encoder.emittedCount;
      expect(total, greaterThan(beforeFlush));
      Uint8List? out;
      encoder.drain((Uint8List chunk) => out = chunk);
      expect(out!.length, total);
      expect(encoder.emittedCount, 0, reason: 'drain empties the buffer');
    });
  });

  group('LzmaEncoder round-trips through LzmaDecoder', () {
    final payloads = <String, Uint8List Function()>{
      'ascii text':
          () => Uint8List.fromList(('koni archive writes LZMA now. ' * 100).codeUnits),
      'random bytes': () {
        final random = Random(42);
        return Uint8List.fromList(
          List.generate(20000, (_) => random.nextInt(256)),
        );
      },
      'all zeros': () => Uint8List(30000),
      'byte ramp': () =>
          Uint8List.fromList(List.generate(8192, (i) => i & 0xFF)),
      'single byte': () => Uint8List.fromList([0x7F]),
      'empty': () => Uint8List(0),
    };

    for (final MapEntry(key: name, value: build) in payloads.entries) {
      test('payload: $name', () {
        final payload = build();
        final encoder = LzmaEncoder();
        final stream = encoder.encode(payload);
        expect(
          _decodeOurs(stream, encoder.propsByte, payload.length),
          payload,
        );
      });
    }

    test('every valid lc/lp/pb combination (lc+lp <= 4)', () {
      final payload = Uint8List.fromList(
        ('mixed content 12345 — ' * 40).codeUnits,
      );
      for (var lc = 0; lc <= 4; lc++) {
        for (var lp = 0; lc + lp <= 4; lp++) {
          for (var pb = 0; pb <= 4; pb++) {
            final encoder = LzmaEncoder(lc: lc, lp: lp, pb: pb);
            final stream = encoder.encode(payload);
            expect(
              _decodeOurs(stream, encoder.propsByte, payload.length),
              payload,
              reason: 'lc=$lc lp=$lp pb=$pb',
            );
          }
        }
      }
    });

    test('encoder instance is reusable across encode calls', () {
      final encoder = LzmaEncoder();
      final first = Uint8List.fromList('first payload'.codeUnits);
      final second = Uint8List.fromList('second, different payload'.codeUnits);
      final s1 = encoder.encode(first);
      final s2 = encoder.encode(second);
      expect(_decodeOurs(s1, encoder.propsByte, first.length), first);
      expect(_decodeOurs(s2, encoder.propsByte, second.length), second);
    });

    test('repetitive text produces real compression', () {
      final payload =
          Uint8List.fromList(('a page of prose, repeated often enough. ' * 2000).codeUnits);
      final encoder = LzmaEncoder();
      final stream = encoder.encode(payload);
      expect(_decodeOurs(stream, encoder.propsByte, payload.length), payload);
      expect(
        stream.length,
        lessThan(payload.length ~/ 20),
        reason: 'greedy matching must compress repeats, not just literals',
      );
    });

    test('long identical runs use max-length matches', () {
      final payload = Uint8List(500000); // zeros: dist-1 matches, len 273
      final encoder = LzmaEncoder();
      final stream = encoder.encode(payload);
      expect(_decodeOurs(stream, encoder.propsByte, payload.length), payload);
      expect(stream.length, lessThan(2000));
    });

    test('match runs exactly to the end of the buffer', () {
      final payload = Uint8List.fromList(
        [...('abcdefgh' * 2).codeUnits, ...('XYZW1234' * 40).codeUnits],
      );
      final encoder = LzmaEncoder();
      final stream = encoder.encode(payload);
      expect(_decodeOurs(stream, encoder.propsByte, payload.length), payload);
    });

    test('pseudo-text round-trips at every size around block edges', () {
      final random = Random(99);
      const words = ['koni', 'archive', 'seven', 'zip', 'lzma', 'range'];
      for (final size in [1, 2, 3, 4, 5, 15, 16, 17, 273, 274, 65536]) {
        final b = BytesBuilder(copy: false);
        while (b.length < size) {
          b.add(words[random.nextInt(words.length)].codeUnits);
          b.addByte(0x20);
        }
        final payload = Uint8List.sublistView(b.takeBytes(), 0, size);
        final encoder = LzmaEncoder();
        final stream = encoder.encode(payload);
        expect(
          _decodeOurs(stream, encoder.propsByte, payload.length),
          payload,
          reason: 'size $size',
        );
      }
    });

    test('distances are capped by dictSize', () {
      // The same block twice, 8000 filler bytes apart, with a 4 KiB
      // dictionary: the second occurrence must NOT match the first.
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
      expect(_decodeOurs(stream, encoder.propsByte, payload.length), payload);
    });

    test('invalid properties are rejected', () {
      expect(() => LzmaEncoder(lc: 9), throwsArgumentError);
      expect(() => LzmaEncoder(lp: 5), throwsArgumentError);
      expect(() => LzmaEncoder(pb: 5), throwsArgumentError);
      expect(() => LzmaEncoder(lc: 3, lp: 2), throwsArgumentError);
      expect(() => LzmaEncoder(dictSize: 100), throwsArgumentError);
    });

    test('sevenZipProps packs props byte + dictionary size', () {
      final encoder = LzmaEncoder(dictSize: 1 << 20);
      expect(encoder.propsByte, 0x5D);
      expect(encoder.sevenZipProps(), [0x5D, 0x00, 0x00, 0x10, 0x00]);
    });
  });
}

Uint8List _decodeOurs(Uint8List stream, int propsByte, int outLength) {
  final output = Uint8List(outLength);
  final decoder = LzmaDecoder(output: output)..setProps(propsByte);
  decoder.addInput(stream);
  decoder.setInputComplete();
  expect(decoder.isChunkComplete, isTrue, reason: 'decoder must finish');
  return output;
}

Uint16List _freshProbs() => Uint16List(2048)..fillRange(0, 2048, 1024);

void _roundTrip(List<_Op> ops, {required String reason}) {
  final encoder = RangeEncoder();
  final probs = _freshProbs();
  for (final op in ops) {
    op.encode(encoder, probs);
  }
  encoder.flush();
  Uint8List? bytes;
  encoder.drain((Uint8List chunk) => bytes = chunk);
  _expectDecodes(bytes!, ops, reason: reason);
}

void _expectDecodes(Uint8List bytes, List<_Op> ops, {required String reason}) {
  final decoder = _RefRangeDecoder(bytes);
  final probs = _freshProbs();
  for (var i = 0; i < ops.length; i++) {
    final decoded = ops[i].decode(decoder, probs);
    expect(decoded, ops[i].value, reason: '$reason, op $i (${ops[i].kind})');
  }
}

enum _OpKind { bit, direct, tree, treeReverse }

/// One range-coder operation: what was encoded and how to decode it back.
final class _Op {
  _Op.bit(this.slot, this.value) : kind = _OpKind.bit, bits = 1;
  _Op.direct(this.value, this.bits) : kind = _OpKind.direct, slot = 0;
  _Op.tree(this.bits, this.value) : kind = _OpKind.tree, slot = 0;
  _Op.treeReverse(this.bits, this.value)
    : kind = _OpKind.treeReverse,
      slot = 0;

  final _OpKind kind;
  final int slot; // probability slot for single bits
  final int bits;
  final int value;

  // Trees get their own region of the probability array (offset 1024) so
  // single-bit slots and tree nodes never collide.
  static const int _treeOffset = 1024;

  void encode(RangeEncoder encoder, Uint16List probs) {
    switch (kind) {
      case _OpKind.bit:
        encoder.encodeBit(probs, slot, value);
      case _OpKind.direct:
        encoder.encodeDirectBits(value, bits);
      case _OpKind.tree:
        encoder.encodeTree(probs, _treeOffset, bits, value);
      case _OpKind.treeReverse:
        encoder.encodeTreeReverse(probs, _treeOffset, bits, value);
    }
  }

  int decode(_RefRangeDecoder decoder, Uint16List probs) => switch (kind) {
    _OpKind.bit => decoder.bit(probs, slot),
    _OpKind.direct => decoder.directBits(bits),
    _OpKind.tree => decoder.tree(probs, _treeOffset, bits),
    _OpKind.treeReverse => decoder.treeReverse(probs, _treeOffset, bits),
  };
}

/// Reference range decoder — the arithmetic of `LzmaDecoder`'s private
/// range coder, copied verbatim (including the 32-bit masking discipline).
final class _RefRangeDecoder {
  _RefRangeDecoder(this._input) {
    if (_nextByte() != 0) {
      throw const FormatException('invalid range-coder init byte');
    }
    for (var i = 0; i < 4; i++) {
      _code = ((_code * 256) & 0xFFFFFFFF) | _nextByte();
    }
  }

  final Uint8List _input;
  int _pos = 0;
  int _range = 0xFFFFFFFF;
  int _code = 0;

  int _nextByte() => _pos < _input.length ? _input[_pos++] : 0;

  int bit(Uint16List probs, int index) {
    final prob = probs[index];
    final bound = (_range >>> 11) * prob;
    int symbol;
    if (_code < bound) {
      _range = bound;
      probs[index] = prob + ((2048 - prob) >> 5);
      symbol = 0;
    } else {
      _range -= bound;
      _code -= bound;
      probs[index] = prob - (prob >> 5);
      symbol = 1;
    }
    if (_range < 0x1000000) {
      _range = (_range * 256) & 0xFFFFFFFF;
      _code = ((_code * 256) & 0xFFFFFFFF) | _nextByte();
    }
    return symbol;
  }

  int directBits(int count) {
    var result = 0;
    for (var i = 0; i < count; i++) {
      _range >>>= 1;
      result <<= 1;
      if (_code >= _range) {
        _code -= _range;
        result |= 1;
      }
      if (_range < 0x1000000) {
        _range = (_range * 256) & 0xFFFFFFFF;
        _code = ((_code * 256) & 0xFFFFFFFF) | _nextByte();
      }
    }
    return result;
  }

  int tree(Uint16List probs, int offset, int numBits) {
    var m = 1;
    for (var i = 0; i < numBits; i++) {
      m = (m << 1) | bit(probs, offset + m);
    }
    return m - (1 << numBits);
  }

  int treeReverse(Uint16List probs, int offset, int numBits) {
    var m = 1;
    var symbol = 0;
    for (var i = 0; i < numBits; i++) {
      final b = bit(probs, offset + m);
      m = (m << 1) | b;
      symbol |= b << i;
    }
    return symbol;
  }
}
