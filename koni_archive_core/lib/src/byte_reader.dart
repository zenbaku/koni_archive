import 'dart:typed_data';

import 'exceptions.dart';

/// Synchronous cursor over a byte buffer for parsing archive structures.
///
/// All reads advance [position]; reading past the end throws
/// [UnexpectedEofException] (never [RangeError]). Multi-byte reads exist
/// in little- and big-endian variants; archive formats are predominantly
/// little-endian.
final class ByteReader {
  /// Creates a reader over [bytes], starting at offset 0.
  ///
  /// [baseOffset] is added to [position] in error context only; pass the
  /// buffer's offset within the archive so exceptions point at the true
  /// archive offset.
  ByteReader(Uint8List bytes, {int baseOffset = 0})
    : _bytes = bytes,
      _data = ByteData.sublistView(bytes),
      _baseOffset = baseOffset;

  final Uint8List _bytes;
  final ByteData _data;
  final int _baseOffset;
  int _position = 0;

  /// Current offset into the buffer, in bytes.
  int get position => _position;

  /// Moves the cursor to absolute buffer offset [value] (0 ≤ value ≤ length).
  set position(int value) {
    if (value < 0 || value > _bytes.length) {
      throw ArgumentError.value(value, 'position', 'out of range');
    }
    _position = value;
  }

  /// Total length of the underlying buffer, in bytes.
  int get length => _bytes.length;

  /// Bytes left between [position] and the end of the buffer.
  int get remaining => _bytes.length - _position;

  /// Whether the cursor is at the end of the buffer.
  bool get isAtEnd => _position >= _bytes.length;

  void _require(int count) {
    if (count > remaining) {
      throw UnexpectedEofException(
        'need $count byte(s) but only $remaining remain',
        offset: _baseOffset + _position,
      );
    }
  }

  /// Reads one unsigned byte.
  int readUint8() {
    _require(1);
    return _bytes[_position++];
  }

  /// Reads an unsigned 16-bit little-endian integer.
  int readUint16le() => _readUint(2, Endian.little);

  /// Reads an unsigned 16-bit big-endian integer.
  int readUint16be() => _readUint(2, Endian.big);

  /// Reads an unsigned 32-bit little-endian integer.
  int readUint32le() => _readUint(4, Endian.little);

  /// Reads an unsigned 32-bit big-endian integer.
  int readUint32be() => _readUint(4, Endian.big);

  int _readUint(int size, Endian endian) {
    _require(size);
    final value = switch (size) {
      2 => _data.getUint16(_position, endian),
      4 => _data.getUint32(_position, endian),
      _ => throw ArgumentError.value(size, 'size'),
    };
    _position += size;
    return value;
  }

  /// Reads an unsigned 64-bit little-endian integer.
  ///
  /// Composed from two 32-bit reads for dart2js compatibility
  /// (`ByteData.getUint64` is unsupported there). Values above 2^53 − 1
  /// throw [UnsupportedFeatureException] on every platform: one uniform
  /// cap (the dart2js exact-integer limit; ~9 PB dwarfs any real archive
  /// field), which also keeps hostile 64-bit header fields from wrapping
  /// negative on the VM (fuzz invariant).
  int readUint64le() {
    _require(8);
    final lo = _data.getUint32(_position, Endian.little);
    final hi = _data.getUint32(_position + 4, Endian.little);
    return _composeUint64(hi, lo);
  }

  /// Reads an unsigned 64-bit big-endian integer. See [readUint64le] for
  /// platform range notes.
  int readUint64be() {
    _require(8);
    final hi = _data.getUint32(_position, Endian.big);
    final lo = _data.getUint32(_position + 4, Endian.big);
    return _composeUint64(hi, lo);
  }

  int _composeUint64(int hi, int lo) {
    if (hi > 0x1FFFFF) {
      throw UnsupportedFeatureException(
        '64-bit value 0x${hi.toRadixString(16)}${lo.toRadixString(16).padLeft(8, '0')} '
        'exceeds the supported integer range (2^53 - 1)',
        offset: _baseOffset + _position,
      );
    }
    final value = hi * 0x100000000 + lo;
    _position += 8;
    return value;
  }

  /// Reads [count] bytes as a view over the underlying buffer (no copy;
  /// callers must not mutate it).
  Uint8List readBytes(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'must be non-negative');
    }
    _require(count);
    final view = Uint8List.sublistView(_bytes, _position, _position + count);
    _position += count;
    return view;
  }

  /// Advances the cursor by [count] bytes without reading.
  void skip(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'must be non-negative');
    }
    _require(count);
    _position += count;
  }
}
