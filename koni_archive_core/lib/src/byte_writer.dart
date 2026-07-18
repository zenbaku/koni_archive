import 'dart:typed_data';

/// Synchronous, append-only builder for byte structures — the write mirror of
/// [ByteReader], for assembling archive headers (or deliberately malformed ones
/// for tests) by hand.
///
/// Values are written at the current end; [length] tracks how many bytes have
/// accumulated (handy for recording an offset mid-build). Multi-byte writes
/// come in little- and big-endian variants; archive formats are predominantly
/// little-endian. A value that does not fit the requested width throws
/// [ArgumentError] (a caller bug, unlike a reader's [ByteReader] EOF). Call
/// [takeBytes] once to get the result.
final class ByteWriter {
  /// Creates an empty writer.
  ByteWriter();

  // copy: true so the reused [_scratch] view is snapshotted on each add.
  final BytesBuilder _builder = BytesBuilder(copy: true);
  final ByteData _scratch = ByteData(8);

  /// 2^53 − 1: the largest integer dart2js represents exactly, and the cap for
  /// 64-bit writes (matching [ByteReader.readUint64le]). ~9 PB dwarfs any real
  /// archive field.
  static const int _maxSafeInteger = 9007199254740991;

  /// Bytes written so far.
  int get length => _builder.length;

  /// Writes one unsigned byte (0–255).
  void writeUint8(int value) {
    _checkRange(value, 0xFF, 'writeUint8');
    _builder.addByte(value);
  }

  /// Writes an unsigned 16-bit little-endian integer.
  void writeUint16le(int value) =>
      _writeUint(value, 2, Endian.little, 0xFFFF, 'writeUint16le');

  /// Writes an unsigned 16-bit big-endian integer.
  void writeUint16be(int value) =>
      _writeUint(value, 2, Endian.big, 0xFFFF, 'writeUint16be');

  /// Writes an unsigned 32-bit little-endian integer.
  void writeUint32le(int value) =>
      _writeUint(value, 4, Endian.little, 0xFFFFFFFF, 'writeUint32le');

  /// Writes an unsigned 32-bit big-endian integer.
  void writeUint32be(int value) =>
      _writeUint(value, 4, Endian.big, 0xFFFFFFFF, 'writeUint32be');

  void _writeUint(int value, int size, Endian endian, int max, String name) {
    _checkRange(value, max, name);
    switch (size) {
      case 2:
        _scratch.setUint16(0, value, endian);
      case 4:
        _scratch.setUint32(0, value, endian);
    }
    _builder.add(Uint8List.sublistView(_scratch, 0, size));
  }

  /// Writes an unsigned 64-bit little-endian integer.
  ///
  /// Composed from two 32-bit writes for dart2js compatibility
  /// (`ByteData.setUint64` is unsupported there); [value] must be in
  /// `0..2^53-1` (see [_maxSafeInteger]).
  void writeUint64le(int value) {
    _check64(value);
    _scratch.setUint32(0, value % 0x100000000, Endian.little);
    _scratch.setUint32(4, value ~/ 0x100000000, Endian.little);
    _builder.add(Uint8List.sublistView(_scratch, 0, 8));
  }

  /// Writes an unsigned 64-bit big-endian integer. See [writeUint64le] for the
  /// platform range notes.
  void writeUint64be(int value) {
    _check64(value);
    _scratch.setUint32(0, value ~/ 0x100000000, Endian.big);
    _scratch.setUint32(4, value % 0x100000000, Endian.big);
    _builder.add(Uint8List.sublistView(_scratch, 0, 8));
  }

  /// Appends [bytes] verbatim.
  void writeBytes(List<int> bytes) => _builder.add(bytes);

  /// Appends [count] zero bytes (padding).
  void writeZeros(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'must be non-negative');
    }
    if (count > 0) _builder.add(Uint8List(count));
  }

  /// Returns everything written so far as one contiguous buffer, clearing the
  /// writer. Call once when the structure is complete.
  Uint8List takeBytes() => _builder.takeBytes();

  static void _checkRange(int value, int max, String name) {
    if (value < 0 || value > max) {
      throw ArgumentError.value(value, name, 'must be in 0..$max');
    }
  }

  static void _check64(int value) {
    if (value < 0 || value > _maxSafeInteger) {
      throw ArgumentError.value(
        value,
        'value',
        'must be in 0..2^53-1 (the dart2js exact-integer limit)',
      );
    }
  }
}
