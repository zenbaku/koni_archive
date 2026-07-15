import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:glob/glob.dart';
import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_gzip/koni_gzip.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:koni_tar/koni_tar.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:path/path.dart' as p;

/// Registry pre-populated with every built-in format, in detection order.
///
/// This is where the facade registers built-ins *explicitly* (§5 — no
/// import-side-effect registration): each format milestone adds its
/// descriptor here. [Archive.open] uses this registry unless the caller
/// passes their own; add third-party formats either by registering into
/// this instance or by building a custom [ArchiveFormatRegistry].
///
/// Detection order (§5): precise-magic formats belong before TAR, whose v7
/// fallback is a heuristic checksum probe.
final ArchiveFormatRegistry builtInFormats = ArchiveFormatRegistry([
  const ZipFormat(),
  const SevenZFormat(),
  const RarFormat(),
  // A .tar.gz sniffs as the inner TAR (§8 layering).
  const GzipFormat(layeredFormats: [TarFormat()]),
  const TarFormat(),
]);

/// An opened archive, presented as a read-only virtual filesystem (§1):
/// callers stream files out of it and never need to know which format is
/// underneath.
///
/// Obtain one with [Archive.open] (auto-detects the format), [openBytes],
/// or the platform sugar in `package:koni_archive/io.dart` /
/// `package:koni_archive/web.dart`. Reading is streaming-first: [openRead]
/// is the primary API and has bounded memory use regardless of entry size;
/// [readBytes] is an explicit whole-entry convenience.
///
/// Decompression is CPU-bound: Flutter apps should wrap whole-entry reads
/// in `Isolate.run` (entries are immutable and isolate-transferable, §6) —
/// on the web, where isolates don't exist, calls run inline.
final class Archive {
  Archive._(this._reader, this._source);

  final ArchiveReader _reader;
  final ByteSource _source;
  final Set<_OpenEntryStream> _openStreams = {};
  bool _closed = false;

  /// Opens [source], auto-detecting its format against [registry]
  /// (default: [builtInFormats]).
  ///
  /// Parses container metadata eagerly — O(entry count), no content
  /// decompression (§4; per-format caveats such as 7z's compressed header
  /// block are documented in each format package). On success the archive
  /// owns [source] and closes it in [close]; on failure the source is left
  /// open and usable (retry with an explicit `format:`, or close it
  /// yourself).
  ///
  /// [format] is the §5 escape hatch: it skips detection and forces a
  /// format. Callers should never normally need it. [options] tunes reader
  /// behavior (e.g. `verifyChecksums: false`, §7).
  ///
  /// Throws [UnsupportedFormatException] when no registered format matches.
  static Future<Archive> open(
    ByteSource source, {
    ArchiveFormatRegistry? registry,
    ArchiveFormat? format,
    ArchiveReadOptions options = const ArchiveReadOptions(),
  }) async {
    final reader = await (registry ?? builtInFormats).openReader(
      source,
      format: format,
      options: options,
    );
    return Archive._(reader, source);
  }

  /// Opens an in-memory archive: [open] over a [MemoryByteSource].
  static Future<Archive> openBytes(
    Uint8List bytes, {
    ArchiveFormatRegistry? registry,
    ArchiveFormat? format,
    ArchiveReadOptions options = const ArchiveReadOptions(),
  }) => open(
    MemoryByteSource(bytes),
    registry: registry,
    format: format,
    options: options,
  );

  /// Creates a writer that appends a new archive of [format] to [sink]
  /// (Phase 2) — the write counterpart of [open].
  ///
  /// Writing names the format explicitly (there is nothing to auto-detect).
  /// Synchronous: opening a writer does no I/O. Add entries with
  /// [ArchiveWriter.addBytes] / [ArchiveWriter.addStream] /
  /// [ArchiveWriter.addEntry], then call [ArchiveWriter.close] to finalize;
  /// the caller owns [sink] and closes it.
  static ArchiveWriter create(
    ByteSink sink, {
    required ArchiveWriteFormat format,
    ArchiveWriteOptions options = const ArchiveWriteOptions(),
  }) => format.openWriter(sink, options);

  /// The detected (or forced) format of this archive.
  ArchiveFormat get format => _reader.format;

  /// All entries in archive index order, duplicates included (§4).
  List<ArchiveEntry> get entries => _reader.entries;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  // Path -> entry map; built lazily. Map literal iteration order makes the
  // *last* entry with a given path win (§4).
  late final Map<String, ArchiveEntry> _byPath = {
    for (final entry in _reader.entries) entry.path: entry,
  };

  /// Looks up an entry by exact, case-sensitive normalized path (§4).
  ///
  /// Duplicate paths resolve last-wins; returns null when absent. This
  /// resolves *stored* entries only — implicit directories synthesized for
  /// the VFS view (see [directories]) are not returned here.
  ArchiveEntry? entry(String path) => _byPath[path];

  /// Whether a stored entry with exactly this path exists. See [entry].
  bool exists(String path) => _byPath.containsKey(path);

  /// Streams the decoded content of [entry] — the primary read API (§4).
  ///
  /// The stream is single-subscription with bounded memory use regardless
  /// of entry size. Multiple entry streams may be open simultaneously (e.g.
  /// preload page N+1 while displaying page N). Mid-decode failures arrive
  /// as typed [ArchiveException]s through the stream. Cancelling the
  /// subscription releases all resources; [close] errors in-flight streams
  /// with [ArchiveClosedException].
  ///
  /// Entry-scoped problems (unsupported compression, encrypted entry) throw
  /// typed exceptions here — the rest of the archive stays readable (§9).
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    _checkOpen();
    return _OpenEntryStream(this, entry).stream;
  }

  /// [openRead] by path — sugar over [entry] (§4).
  ///
  /// Throws [EntryNotFoundException] when no entry has this exact path.
  Stream<Uint8List> openReadPath(String path) {
    _checkOpen();
    final found = entry(path);
    if (found == null) {
      throw EntryNotFoundException(
        'no entry with path "$path"',
        format: format.name,
        entryPath: path,
      );
    }
    return openRead(found);
  }

  /// Collects [openRead] into one buffer.
  ///
  /// [maxSize] bounds the decoded size (decompression-bomb protection, §7):
  /// exceeding it cancels the decode and throws
  /// [SizeLimitExceededException]. Prefer [openRead] for anything large.
  Future<Uint8List> readBytes(ArchiveEntry entry, {int? maxSize}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in openRead(entry)) {
      if (maxSize != null && builder.length + chunk.length > maxSize) {
        throw SizeLimitExceededException(
          'entry exceeds maxSize of $maxSize byte(s)',
          limit: maxSize,
          format: format.name,
          entryPath: entry.path,
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Closes the archive: errors in-flight entry streams with
  /// [ArchiveClosedException], releases reader resources, and closes the
  /// underlying [ByteSource]. Idempotent (§4).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final open in _openStreams.toList()) {
      open.abort();
    }
    _openStreams.clear();
    await _reader.close();
    await _source.close();
  }

  void _checkOpen() {
    if (_closed) {
      throw ArchiveClosedException(
        'archive is closed',
        format: _reader.format.name,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Virtual-filesystem view (§4): last-wins per path, with implicit
  // directory entries synthesized (many ZIPs omit them).
  // ---------------------------------------------------------------------

  late final _VfsNode _vfsRoot = _buildVfs();

  _VfsNode _buildVfs() {
    final root = _VfsNode('');
    for (final entry in _byPath.values) {
      if (entry.path.isEmpty) continue; // archive-root entries (bare '/')
      final segments = entry.path.split('/');
      var node = root;
      final prefix = StringBuffer();
      for (var i = 0; i < segments.length; i++) {
        if (i > 0) prefix.write('/');
        prefix.write(segments[i]);
        node = node.children.putIfAbsent(
          segments[i],
          () => _VfsNode(prefix.toString()),
        );
      }
      node.entry = entry;
    }
    return root;
  }

  /// The VFS view, in depth-first pre-order (§4 `walk()`).
  ///
  /// Order (documented per §4): each directory precedes its contents;
  /// siblings are visited in code-unit order of their names; the archive
  /// root itself is not emitted. One node per unique path (duplicates
  /// resolve last-wins); implicit parent directories missing from the
  /// archive are synthesized as directory entries with
  /// [ArchiveEntry.uncompressedSize] 0.
  Iterable<ArchiveEntry> walk() sync* {
    yield* _walkNode(_vfsRoot);
  }

  Iterable<ArchiveEntry> _walkNode(_VfsNode node) sync* {
    for (final child in node.children.values) {
      yield child.entry ??= ArchiveEntry(
        path: child.path,
        type: ArchiveEntryType.directory,
        uncompressedSize: 0,
      );
      yield* _walkNode(child);
    }
  }

  /// Regular-file entries of the VFS view, in [walk] order.
  Iterable<ArchiveEntry> get files =>
      walk().where((e) => e.type == ArchiveEntryType.file);

  /// Directory entries of the VFS view (explicit and synthesized), in
  /// [walk] order.
  Iterable<ArchiveEntry> get directories =>
      walk().where((e) => e.type == ArchiveEntryType.directory);

  /// VFS entries whose path matches [pattern]
  /// (`package:glob` syntax, case-sensitive, `/`-separated — e.g.
  /// `ch01/*.webp` or `**.jpg`), in [walk] order.
  Iterable<ArchiveEntry> glob(String pattern) {
    final matcher = Glob(pattern, context: p.url, caseSensitive: true);
    return walk().where((e) => matcher.matches(e.path));
  }
}

class _VfsNode {
  _VfsNode(this.path);

  final String path;

  /// Stored entry, synthesized directory entry (assigned lazily during
  /// walk), or null until first walked.
  ArchiveEntry? entry;

  final SplayTreeMap<String, _VfsNode> children = SplayTreeMap();
}

/// Bookkeeping for one in-flight entry stream: forwards the reader's stream
/// and lets [Archive.close] abort it with a typed error.
final class _OpenEntryStream {
  _OpenEntryStream(this._archive, this._entry) {
    _controller = StreamController<Uint8List>(
      onListen: _start,
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: _cancel,
    );
    _archive._openStreams.add(this);
  }

  final Archive _archive;
  final ArchiveEntry _entry;
  late final StreamController<Uint8List> _controller;
  StreamSubscription<Uint8List>? _subscription;

  Stream<Uint8List> get stream => _controller.stream;

  void _start() {
    if (_controller.isClosed) return; // aborted before first listen
    _subscription = _archive._reader
        .openRead(_entry)
        .listen(
          _controller.add,
          onError: _controller.addError,
          onDone: () {
            _detach();
            _controller.close();
          },
        );
  }

  Future<void> _cancel() async {
    _detach();
    await _subscription?.cancel();
  }

  void abort() {
    _detach();
    final sub = _subscription;
    _subscription = null;
    unawaited(sub?.cancel());
    if (!_controller.isClosed) {
      _controller.addError(
        ArchiveClosedException(
          'archive was closed while streaming entry',
          format: _archive._reader.format.name,
          entryPath: _entry.path,
        ),
      );
      unawaited(_controller.close());
    }
  }

  void _detach() => _archive._openStreams.remove(this);
}
