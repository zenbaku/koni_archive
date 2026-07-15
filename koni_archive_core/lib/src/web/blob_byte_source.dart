import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../byte_source.dart';
import '../exceptions.dart';

/// A [ByteSource] over a browser [web.Blob] (or `File`, which extends Blob).
///
/// Reads use `Blob.slice(...).arrayBuffer()`, which browsers execute
/// independently per call — true pread semantics, so a reader can fetch
/// several entries' bytes concurrently. Works under both dart2js and
/// dart2wasm.
final class BlobByteSource implements ByteSource {
  /// Creates a source over [blob]. A browser `File` (from an
  /// `<input type=file>` or drag-and-drop) is a Blob and works directly;
  /// pass its `name` as [name] if entry-name derivation matters (§8 gzip).
  BlobByteSource(web.Blob blob, {this.name}) : _blob = blob, length = blob.size;

  final web.Blob _blob;
  bool _closed = false;

  @override
  final String? name;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    checkByteSourceRange(this, offset, length);
    if (_closed) {
      throw ArchiveClosedException('read($offset, $length) after close()');
    }
    final buffer =
        await _blob.slice(offset, offset + length).arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> close() {
    // Blobs hold no closeable handle; closing just fences further reads.
    _closed = true;
    return Future.value();
  }
}
