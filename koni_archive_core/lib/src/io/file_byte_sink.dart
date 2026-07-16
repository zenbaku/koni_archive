import 'dart:io';
import 'dart:typed_data';

import '../byte_sink.dart';
import '../exceptions.dart';

/// A [ByteSink] that appends to a file on disk (`dart:io`; VM/Flutter-native
/// only). Writes are serialized internally, so sequential `add` calls need
/// not be awaited individually, though awaiting bounds memory.
final class FileByteSink implements ByteSink {
  FileByteSink._(this._file);

  /// Opens (creating/truncating) [path] for writing.
  static Future<FileByteSink> create(String path) async {
    final file = await File(path).open(mode: FileMode.write);
    return FileByteSink._(file);
  }

  final RandomAccessFile _file;
  int _length = 0;
  bool _closed = false;
  Future<void> _lock = Future.value();

  @override
  int get length => _length;

  @override
  Future<void> add(Uint8List bytes) => _synchronized(() async {
    if (_closed) {
      throw ArchiveClosedException('add(${bytes.length}) after close()');
    }
    await _file.writeFrom(bytes);
    _length += bytes.length;
  });

  @override
  Future<void> close() => _synchronized(() async {
    if (_closed) return;
    _closed = true;
    await _file.flush();
    await _file.close();
  });

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}
