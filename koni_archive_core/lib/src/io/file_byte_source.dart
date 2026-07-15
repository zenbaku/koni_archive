import 'dart:io';
import 'dart:typed_data';

import '../byte_source.dart';
import '../exceptions.dart';

/// A [ByteSource] over a file on disk (`dart:io`; VM/Flutter-native only).
///
/// `dart:io`'s [RandomAccessFile] has a single seek cursor, so concurrent
/// positional reads are serialized internally on one file handle — the
/// pread *semantics* of the [ByteSource] contract hold (overlapping [read]
/// calls never interfere), reads just don't run in parallel at the OS level.
final class FileByteSource implements ByteSource {
  FileByteSource._(this._file, this.length, this.name);

  /// Opens [path] for random-access reading.
  static Future<FileByteSource> open(String path) async {
    final file = await File(path).open();
    final length = await file.length();
    return FileByteSource._(file, length, path);
  }

  /// The path this source was opened from.
  @override
  final String name;

  final RandomAccessFile _file;
  bool _closed = false;

  // Serialization chain for the shared seek cursor (pread semantics).
  Future<void> _lock = Future.value();

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) {
    checkByteSourceRange(this, offset, length);
    return _synchronized(() async {
      if (_closed) {
        throw ArchiveClosedException('read($offset, $length) after close()');
      }
      await _file.setPosition(offset);
      final result = Uint8List(length);
      var filled = 0;
      while (filled < length) {
        final got = await _file.readInto(result, filled, length);
        if (got <= 0) {
          // The file shrank underneath us after open().
          throw UnexpectedEofException(
            'file ended at ${offset + filled} while reading '
            '$length byte(s) at offset $offset',
            offset: offset + filled,
          );
        }
        filled += got;
      }
      return result;
    });
  }

  @override
  Future<void> close() => _synchronized(() async {
    if (_closed) return;
    _closed = true;
    await _file.close();
  });

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}
