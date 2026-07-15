/// `dart:io` sugar for the koni_archive facade — explicit opt-in import for
/// VM and Flutter-native platforms (§2). Re-exports the platform-neutral
/// facade, so a VM program needs only this one import.
library;

import 'dart:typed_data';

import 'package:koni_archive_core/io.dart';

import 'koni_archive.dart';

export 'package:koni_archive_core/io.dart' show FileByteSink, FileByteSource;

export 'koni_archive.dart';

/// Opens the archive file at [path], auto-detecting its format.
///
/// Sugar for [Archive.open] over a [FileByteSource]. (A static
/// `Archive.openFile` is impossible without pulling `dart:io` into the
/// platform-neutral main library, hence a top-level function — see
/// `doc/notes.md`.) The file is closed if opening fails.
Future<Archive> openArchiveFile(
  String path, {
  ArchiveFormatRegistry? registry,
  ArchiveFormat? format,
  ArchiveReadOptions options = const ArchiveReadOptions(),
}) async {
  final source = await FileByteSource.open(path);
  try {
    return await Archive.open(
      source,
      registry: registry,
      format: format,
      options: options,
    );
  } catch (_) {
    await source.close();
    rethrow;
  }
}

/// Creates a writer that appends a new archive of [format] to the file at
/// [path] (Phase 2), creating or truncating it.
///
/// Sugar for [Archive.create] over a [FileByteSink]. Add entries, then call
/// `close()` on the returned writer — which also flushes and closes the
/// file. On failure to open the file, no writer is returned.
Future<ArchiveWriter> createArchiveFile(
  String path, {
  required ArchiveWriteFormat format,
  ArchiveWriteOptions options = const ArchiveWriteOptions(),
}) async {
  final sink = await FileByteSink.create(path);
  try {
    return _ClosingWriter(
      Archive.create(sink, format: format, options: options),
      sink,
    );
  } catch (_) {
    await sink.close();
    rethrow;
  }
}

/// Wraps a writer so `close()` also closes the file sink it owns.
class _ClosingWriter implements ArchiveWriter {
  _ClosingWriter(this._inner, this._sink);

  final ArchiveWriter _inner;
  final FileByteSink _sink;

  @override
  ArchiveWriteFormat get format => _inner.format;

  @override
  Future<ArchiveEntry> addStream(
    ArchiveEntrySpec spec,
    Stream<Uint8List> content, {
    required int size,
  }) => _inner.addStream(spec, content, size: size);

  @override
  Future<ArchiveEntry> addBytes(ArchiveEntrySpec spec, Uint8List content) =>
      _inner.addBytes(spec, content);

  @override
  Future<ArchiveEntry> addEntry(ArchiveEntrySpec spec) => _inner.addEntry(spec);

  @override
  Future<void> close() async {
    await _inner.close();
    await _sink.close();
  }
}
