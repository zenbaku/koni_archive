import 'dart:typed_data';

import 'lzma_encoder.dart';

/// LZMA2 compression: chunked LZMA with reset control, the encode
/// direction of `Lzma2Decoder`. 7z's default codec and xz's
/// payload format.
///
/// Buffer-based one-shot like [LzmaEncoder], which it drives through the
/// chunk-wise API: each chunk is its own range-coded unit (every LZMA2
/// chunk restarts the range coder) while the probability model and the
/// dictionary persist across chunks. Chunks whose compressed form would
/// not be smaller are re-emitted as uncompressed chunks; the trial encode
/// has then already advanced the model past symbols the decoder will never
/// see, so the next compressed chunk carries a state reset to bring both
/// sides back into lockstep.
///
/// The stream is self-terminated by the 0x00 control byte, and the first
/// chunk always resets props + state + dictionary, exactly the shape
/// liblzma and 7zz emit and require.
final class Lzma2Encoder {
  /// Creates an encoder; parameters mirror [LzmaEncoder]'s.
  ///
  /// [chunkSize] caps each compressed chunk's unpacked bytes (default and
  /// maximum: the format's 2 MiB ceiling, less the longest match a chunk's
  /// final token may append past the target).
  Lzma2Encoder({
    int lc = 3,
    int lp = 0,
    int pb = 2,
    int dictSize = 1 << 23,
    this.chunkSize = _maxChunkUnpack,
  }) : _lzma = LzmaEncoder(lc: lc, lp: lp, pb: pb, dictSize: dictSize) {
    if (chunkSize < (1 << 12) || chunkSize > _maxChunkUnpack) {
      throw ArgumentError.value(
        chunkSize,
        'chunkSize',
        'must be in [4 KiB, $_maxChunkUnpack]',
      );
    }
  }

  /// Unpacked bytes per compressed chunk (a testing/tuning seam; the
  /// default is the format ceiling).
  final int chunkSize;

  final LzmaEncoder _lzma;

  /// The 21-bit unpacked-size field, less the 272 bytes a final match may
  /// overshoot the search target by.
  static const int _maxChunkUnpack = (1 << 21) - 273;

  /// The 16-bit packed-size field (stored minus one, so 64 Ki exactly).
  static const int _chunkPackLimit = 1 << 16;

  /// Copy chunks carry a plain 16-bit size field.
  static const int _maxCopyChunk = 1 << 16;

  /// The 7z coder attribute byte: the smallest encodable dictionary size
  /// (of the form `(2 | bit) << k`) covering [LzmaEncoder.dictSize].
  int get dictSizeProp {
    for (var v = 0; v < 40; v++) {
      // Multiplication, not a single shift: (2|1) << 30 exceeds the 32-bit
      // range dart2js bitwise ops are defined on; products stay exact.
      final size = (2 + (v & 1)) * 2048 * (1 << (v ~/ 2));
      if (size >= _lzma.dictSize) return v;
    }
    return 40;
  }

  /// Encodes all of [data] as a complete LZMA2 stream, including the 0x00
  /// end marker.
  Uint8List encode(Uint8List data) {
    final out = BytesBuilder(copy: false);
    _lzma.bind(data);

    var pos = 0;
    var propsSent = false;
    var anyChunkEmitted = false;
    // Set when a trial encode was discarded for an uncompressed chunk: the
    // encoder model saw symbols the decoder will not, so both sides reset.
    var needStateReset = false;

    while (pos < data.length) {
      final resetApplied = needStateReset;
      if (needStateReset) {
        _lzma.resetState();
      }
      final target =
          data.length - pos < chunkSize ? data.length : pos + chunkSize;
      final end = _lzma.encodeChunk(pos, target, packLimit: _chunkPackLimit);
      final packed = _lzma.takeChunk();
      final unpacked = end - pos;

      if (packed.length >= unpacked) {
        // Uncompressed fallback (ratio, and the only correct move for
        // incompressible data): raw copy chunks, then a state reset before
        // the next compressed chunk.
        _emitCopyChunks(out, data, pos, end, dictReset: !anyChunkEmitted);
        needStateReset = true;
      } else {
        final resetBits =
            !propsSent
                ? (anyChunkEmitted ? 2 : 3)
                : resetApplied
                ? 1
                : 0;
        final u = unpacked - 1;
        final p = packed.length - 1;
        out
          ..addByte(0x80 | (resetBits << 5) | (u >> 16))
          ..addByte((u >> 8) & 0xFF)
          ..addByte(u & 0xFF)
          ..addByte(p >> 8)
          ..addByte(p & 0xFF);
        if (resetBits >= 2) out.addByte(_lzma.propsByte);
        out.add(packed);
        propsSent = true;
        needStateReset = false;
      }
      anyChunkEmitted = true;
      pos = end;
    }

    out.addByte(0); // end marker
    return out.takeBytes();
  }

  void _emitCopyChunks(
    BytesBuilder out,
    Uint8List data,
    int from,
    int to, {
    required bool dictReset,
  }) {
    var pos = from;
    var control = dictReset ? 1 : 2;
    while (pos < to) {
      final take = to - pos < _maxCopyChunk ? to - pos : _maxCopyChunk;
      out
        ..addByte(control)
        ..addByte((take - 1) >> 8)
        ..addByte((take - 1) & 0xFF)
        ..add(Uint8List.sublistView(data, pos, pos + take));
      pos += take;
      control = 2;
    }
  }
}
