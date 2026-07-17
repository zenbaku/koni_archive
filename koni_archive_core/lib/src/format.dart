import 'dart:typed_data';

import 'byte_source.dart';
import 'entry.dart';
import 'exceptions.dart';
import 'read_options.dart';
import 'reader.dart';

/// Descriptor for one archive format: how to detect it and how to open it.
/// Format packages implement one of these; third parties can implement
/// their own and register it: the format set is open, never a closed enum.
abstract class ArchiveFormat {
  /// Const-constructable so format descriptors can be compile-time constants.
  const ArchiveFormat();

  /// Short lower-case format name (e.g. `zip`, `tar`), used in diagnostics
  /// and [ArchiveException.format].
  String get name;

  /// Whether [source] looks like this format.
  ///
  /// Must return `false` (not throw) for input that simply isn't this
  /// format. May read wherever it needs (magic bytes are not always at
  /// offset 0: ZIP detection scans backward from EOF, TAR magic is at
  /// offset 257), but should read as little as possible: detection runs
  /// against every registered format in turn. An [ArchiveException] escaping
  /// this method (e.g. [UnexpectedEofException] from a source shorter than a
  /// probe) is treated by the registry as "does not match".
  Future<bool> matches(ByteSource source);

  /// Opens [source] as this format and applies the decompression-bomb guards
  /// in [options] around the reader.
  ///
  /// This is the stable entry point every caller (the facade, the registry, a
  /// direct `Format().openReader(...)` call) goes through. Format packages do
  /// **not** override it; they override [createReader]. Keeping the guards
  /// here — not in the facade — is what makes them impossible to bypass by
  /// using a format's reader directly, and gives them to third-party formats
  /// for free.
  ///
  /// Enforces [ArchiveReadOptions.maxEntryCount] once the index is parsed and
  /// wraps the reader so [ArchiveReadOptions.maxEntrySize] bounds every
  /// streamed entry. Both are no-ops (a pass-through reader) when their option
  /// is null.
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    final reader = await createReader(source, options);
    final maxCount = options.maxEntryCount;
    if (maxCount != null && reader.entries.length > maxCount) {
      // Post-parse floor: readers that learn the count up front reject
      // earlier, but this guarantees the limit holds for every format.
      await reader.close();
      throw SizeLimitExceededException(
        'archive declares ${reader.entries.length} entries, over the '
        'maxEntryCount limit of $maxCount',
        limit: maxCount,
        format: reader.format.name,
      );
    }
    final maxSize = options.maxEntrySize;
    if (maxSize == null) return reader;
    return _BoundedArchiveReader(reader, maxSize);
  }

  /// Opens [source] as this format, eagerly parsing container metadata
  /// (O(entry count), no content decode), honoring [options]. **This is the
  /// method format packages implement**; application code calls [openReader]
  /// (which additionally enforces the bomb-limit options).
  ///
  /// Called by [openReader] after [matches], or directly when the caller
  /// forces a format. Throws a typed [ArchiveException] if the source is not
  /// a well-formed archive of this format. Must not close [source].
  Future<ArchiveReader> createReader(
    ByteSource source,
    ArchiveReadOptions options,
  );
}

/// Wraps a format reader so that [ArchiveReadOptions.maxEntrySize] bounds
/// every streamed entry. A decoded entry that grows past the limit aborts the
/// underlying decode (the `await for` cancels its subscription) and errors the
/// stream with [SizeLimitExceededException]. Entry identity, [entries] order,
/// and [close] pass straight through, so the reader contract is preserved.
class _BoundedArchiveReader implements ArchiveReader {
  _BoundedArchiveReader(this._inner, this._maxEntrySize);

  final ArchiveReader _inner;
  final int _maxEntrySize;

  @override
  ArchiveFormat get format => _inner.format;

  @override
  List<ArchiveEntry> get entries => _inner.entries;

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) =>
      _bounded(_inner.openRead(entry), entry);

  Stream<Uint8List> _bounded(
    Stream<Uint8List> source,
    ArchiveEntry entry,
  ) async* {
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      // `> _maxEntrySize`, so a limit set to an entry's exact size passes;
      // matches `Archive.readBytes`'s `maxSize` boundary. Throw before
      // yielding the over-limit chunk, so no over-limit bytes reach the
      // caller.
      if (total > _maxEntrySize) {
        throw SizeLimitExceededException(
          'entry "${entry.path}" decoded past the maxEntrySize limit of '
          '$_maxEntrySize byte(s)',
          limit: _maxEntrySize,
          format: _inner.format.name,
          entryPath: entry.path,
        );
      }
      yield chunk;
    }
  }

  @override
  Future<void> close() => _inner.close();
}

/// Ordered, mutable registry of [ArchiveFormat]s, what makes koni_archive
/// an ecosystem: new formats plug in without touching core.
///
/// The facade owns a registry pre-populated with the built-in formats;
/// callers can build their own to add formats or restrict the set.
final class ArchiveFormatRegistry {
  /// Creates a registry, optionally pre-populated with [formats].
  ArchiveFormatRegistry([Iterable<ArchiveFormat> formats = const []])
    : _formats = List.of(formats);

  final List<ArchiveFormat> _formats;

  /// Registered formats, in registration order. Unmodifiable view.
  List<ArchiveFormat> get formats => List.unmodifiable(_formats);

  /// Appends [format] to the registry.
  ///
  /// Detection probes formats in registration order and the first match
  /// wins, so register formats with cheap, precise magic checks first.
  void register(ArchiveFormat format) => _formats.add(format);

  /// Probes every registered format in order; returns the first whose
  /// [ArchiveFormat.matches] accepts [source], or null when none does.
  ///
  /// A format whose probe throws [ArchiveException] is treated as
  /// non-matching (a 3-byte input must not abort detection just because one
  /// format's probe reads 4 bytes). Non-[ArchiveException] errors are bugs
  /// and propagate.
  Future<ArchiveFormat?> detect(ByteSource source) async {
    for (final format in _formats) {
      try {
        if (await format.matches(source)) return format;
      } on ArchiveException {
        continue;
      }
    }
    return null;
  }

  /// Detects the format of [source] and opens it: the detection driver
  /// (M1) behind `Archive.open`.
  ///
  /// [format] forces a specific format, skipping detection (the escape
  /// hatch, callers should never normally need it). Throws
  /// [UnsupportedFormatException] when no registered format matches. Does
  /// not take ownership of [source]: on failure the source remains open and
  /// usable.
  Future<ArchiveReader> openReader(
    ByteSource source, {
    ArchiveFormat? format,
    ArchiveReadOptions options = const ArchiveReadOptions(),
  }) async {
    final matched = format ?? await detect(source);
    if (matched == null) {
      throw UnsupportedFormatException(
        'none of the ${_formats.length} registered format(s) '
        '(${_formats.map((f) => f.name).join(', ')}) matches the input',
      );
    }
    return matched.openReader(source, options);
  }
}
