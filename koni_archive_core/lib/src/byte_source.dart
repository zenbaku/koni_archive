import 'dart:typed_data';

import 'exceptions.dart';

/// Random-access byte source — the input abstraction every archive reader
/// consumes (PROMPT_V1.md §3). Never a file path, never a raw stream.
///
/// ## Contract
///
/// - **pread semantics**: implementations MUST support concurrent positional
///   reads — overlapping in-flight [read] calls must not interfere with each
///   other. There is no shared cursor.
/// - [read] returns **exactly** `length` bytes. A range that extends past
///   [length] throws [UnexpectedEofException] (typed, so corrupt headers
///   pointing past EOF surface as archive errors, never [RangeError]).
///   Negative `offset` or `length` is a programmer error ([ArgumentError]).
/// - The returned buffer MAY be a view over shared memory; callers must not
///   mutate it, and implementations must not reuse it for later reads.
/// - After [close], [read] throws [ArchiveClosedException]. [close] is
///   idempotent.
/// - Nothing may assume the source is local or cheap to read: an HTTP-range
///   implementation must be possible without core changes. Callers should
///   read in as few, as large, requests as practical.
abstract interface class ByteSource {
  /// Optional display name for the source (a file path, a browser File
  /// name), used by formats that derive entry names from the container
  /// (e.g. a bare `.gz` with no FNAME field, §8). Null when the source has
  /// no meaningful name.
  String? get name;

  /// Total length of the source in bytes.
  int get length;

  /// Reads exactly [length] bytes starting at byte [offset].
  ///
  /// Throws [UnexpectedEofException] if the range extends past the end of
  /// the source and [ArchiveClosedException] if the source is closed.
  Future<Uint8List> read(int offset, int length);

  /// Releases any resources held by the source. Idempotent.
  Future<void> close();
}

/// A [ByteSource] over an in-memory byte buffer.
///
/// Reads return views over the original buffer (no copies, §10); mutating
/// the buffer after construction is visible through this source.
final class MemoryByteSource implements ByteSource {
  /// Creates a source over [bytes]. The buffer is not copied. [name] is an
  /// optional display name (see [ByteSource.name]).
  MemoryByteSource(Uint8List bytes, {this.name}) : _bytes = bytes;

  final Uint8List _bytes;
  bool _closed = false;

  @override
  final String? name;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) {
    final view = readSync(offset, length);
    return Future.value(view);
  }

  /// Synchronous variant of [read] with the same contract. In-memory data
  /// needs no event-loop round trip; readers that know they hold a
  /// [MemoryByteSource] may use this on hot paths.
  Uint8List readSync(int offset, int length) {
    checkByteSourceRange(this, offset, length);
    if (_closed) {
      throw ArchiveClosedException('read($offset, $length) after close()');
    }
    return Uint8List.sublistView(_bytes, offset, offset + length);
  }

  @override
  Future<void> close() {
    _closed = true;
    return Future.value();
  }
}

/// Validates a `read(offset, length)` request against [source]'s length.
///
/// Shared helper for [ByteSource] implementations: throws [ArgumentError]
/// for negative values (programmer error) and [UnexpectedEofException] when
/// the range extends past the end of the source (attacker-controlled header
/// fields land here, §7).
void checkByteSourceRange(ByteSource source, int offset, int length) {
  if (offset < 0) {
    throw ArgumentError.value(offset, 'offset', 'must be non-negative');
  }
  if (length < 0) {
    throw ArgumentError.value(length, 'length', 'must be non-negative');
  }
  if (offset + length > source.length) {
    throw UnexpectedEofException(
      'read of $length byte(s) at offset $offset extends past the end of '
      'the ${source.length}-byte source',
      offset: offset,
    );
  }
}
