import 'dart:typed_data';

/// Shared Merkle–Damgård framing for the SHA family (P3-1).
///
/// SHA-1 and SHA-256 differ only in state size and compression function;
/// the 64-byte block buffering, `0x80` padding, and big-endian bit-length
/// trailer are identical and live here. Subclasses implement [compress]
/// over one 64-byte block.
///
/// The usage model matches core's `Crc32`: feed chunks with [add], then
/// [finish] once. [copy] snapshots the running state — needed by KDFs that
/// take intermediate digests mid-stream (RAR4's, via P3-5) and by HMAC's
/// precomputed pad states.
abstract base class BlockHash {
  /// Creates a hash in its initial state.
  BlockHash();

  /// Copies the running state of [source] (buffered bytes included).
  ///
  /// Only running states can be copied: [finish] repurposes the block
  /// buffer for padding, so a finished hash no longer has a resumable
  /// state to snapshot.
  BlockHash.fromState(BlockHash source)
    : _totalBytes = source._totalBytes,
      _bufferLength = source._bufferLength {
    if (source._finished) {
      throw StateError('copy() after finish()');
    }
    _buffer.setRange(0, source._bufferLength, source._buffer);
  }

  /// Block size of the SHA family, in bytes.
  static const int blockSize = 64;

  /// Digest length in bytes (20 for SHA-1, 32 for SHA-256).
  int get digestSize;

  final Uint8List _buffer = Uint8List(blockSize);
  int _bufferLength = 0;
  int _totalBytes = 0; // Bounded by the 2^53-1 convention; exact on web.
  bool _finished = false;

  /// Compresses the 64 bytes at `block[offset..offset+64)` into the state.
  void compress(Uint8List block, int offset);

  /// Writes the state words to [out] big-endian.
  void writeDigest(Uint8List out);

  /// Returns an independent copy of the running state.
  BlockHash copy();

  /// Updates the hash with `chunk[start..end)`.
  void add(Uint8List chunk, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, chunk.length);
    if (_finished) {
      throw StateError('add() after finish()');
    }
    var i = start;
    _totalBytes += stop - start;
    if (_bufferLength > 0) {
      final take =
          blockSize - _bufferLength < stop - i
              ? blockSize - _bufferLength
              : stop - i;
      _buffer.setRange(_bufferLength, _bufferLength + take, chunk, i);
      _bufferLength += take;
      i += take;
      if (_bufferLength < blockSize) return;
      compress(_buffer, 0);
      _bufferLength = 0;
    }
    for (; i + blockSize <= stop; i += blockSize) {
      compress(chunk, i);
    }
    if (i < stop) {
      _buffer.setRange(0, stop - i, chunk, i);
      _bufferLength = stop - i;
    }
  }

  /// Pads, compresses the final block(s), and returns the digest. The hash
  /// cannot be updated afterwards; snapshot with [copy] first to continue
  /// a running stream.
  Uint8List finish() {
    if (_finished) {
      throw StateError('finish() called twice');
    }
    _finished = true;
    final bytes = _totalBytes;
    _buffer[_bufferLength++] = 0x80;
    if (_bufferLength > blockSize - 8) {
      _buffer.fillRange(_bufferLength, blockSize, 0);
      compress(_buffer, 0);
      _bufferLength = 0;
    }
    _buffer.fillRange(_bufferLength, blockSize - 8, 0);
    // 64-bit big-endian bit count, kept within web-safe arithmetic: the
    // high word via division, the low word from the 29 low bits only —
    // no shift ever sees a value ≥ 2^32 (dart2js §gotchas).
    final high = bytes ~/ 0x20000000;
    final low = (bytes & 0x1FFFFFFF) << 3;
    _buffer[blockSize - 8] = (high >>> 24) & 0xFF;
    _buffer[blockSize - 7] = (high >>> 16) & 0xFF;
    _buffer[blockSize - 6] = (high >>> 8) & 0xFF;
    _buffer[blockSize - 5] = high & 0xFF;
    _buffer[blockSize - 4] = low >>> 24;
    _buffer[blockSize - 3] = (low >>> 16) & 0xFF;
    _buffer[blockSize - 2] = (low >>> 8) & 0xFF;
    _buffer[blockSize - 1] = low & 0xFF;
    compress(_buffer, 0);
    final out = Uint8List(digestSize);
    writeDigest(out);
    return out;
  }
}
