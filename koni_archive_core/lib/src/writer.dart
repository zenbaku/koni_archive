import 'dart:typed_data';

import 'byte_sink.dart';
import 'entry.dart';
import 'write_options.dart';

/// Immutable description of an entry to write (Phase 2) — the input mirror
/// of [ArchiveEntry].
///
/// Only fields a *caller* controls appear here: reader-derived outputs
/// (`crc32`, `compressedSize`, `pathEscapedRoot`, `isEncrypted`) are absent
/// because the writer computes or rejects them. Reuses [ArchiveEntryType]
/// and [ArchiveCompression] rather than parallel enums.
final class ArchiveEntrySpec {
  /// Describes an entry to write.
  ///
  /// [path] is validated by the writer (see [ArchiveWriter.addStream]).
  /// [modified], when given, must be UTC.
  ArchiveEntrySpec({
    required this.path,
    this.type = ArchiveEntryType.file,
    this.modified,
    this.posixMode,
    this.linkTarget,
    this.compression,
  }) : assert(modified == null || modified.isUtc, 'modified must be UTC (§4)'),
       assert(
         type != ArchiveEntryType.symlink &&
                 type != ArchiveEntryType.hardlink ||
             linkTarget != null,
         'symlink/hardlink entries need a linkTarget',
       );

  /// Desired entry path (see [ArchiveWriter.addStream] for validation).
  final String path;

  /// The kind of entry to write.
  final ArchiveEntryType type;

  /// Modification time (UTC), or null to use the writer's default.
  final DateTime? modified;

  /// POSIX permission bits, when the format records them.
  final int? posixMode;

  /// Link target for symlink/hardlink entries.
  final String? linkTarget;

  /// Per-entry compression override; null uses the archive default
  /// ([ArchiveWriteOptions.compression], else the format's default).
  final ArchiveCompression? compression;
}

/// Writes entries to a [ByteSink] in one archive format — the SPI a format
/// package implements for writing, and what application code drives via the
/// `Archive.create` facade. The write mirror of `ArchiveReader`.
///
/// ## Contract
///
/// - Entries are written in call order (archives are sequential). Content
///   for [addStream] is consumed as a single-subscription stream with
///   bounded memory.
/// - [addStream]/[addBytes]/[addEntry] return the resulting [ArchiveEntry]
///   (with computed CRC and sizes), so a write-then-read round trip is
///   symmetric.
/// - Every path is validated (rejecting absolute paths and `..` escapes);
///   see [addStream].
/// - [close] finalizes the archive (e.g. TAR end blocks, the ZIP central
///   directory) and must be called exactly once; it does not close the
///   underlying [ByteSink] (the caller owns it).
abstract class ArchiveWriter {
  /// The format this writer produces.
  ArchiveWriteFormat get format;

  /// Writes a file entry, streaming [content] (exactly [size] bytes) with
  /// bounded memory.
  ///
  /// [size] is required: TAR records it in the header *before* the data, so
  /// unknown-size streaming would force whole-entry buffering — an explicit
  /// non-goal here (callers adding from disk or memory always know the
  /// size). Streaming fewer or more than [size] bytes is a
  /// [SizeLimitExceededException] / [CorruptArchiveException].
  ///
  /// [ArchiveEntrySpec.path] is rejected with an [ArgumentError] if it is
  /// absolute (leading `/` or a drive letter) or escapes the archive root
  /// via `..`; backslashes are normalized to `/`. Duplicate paths are
  /// permitted (ZIP/TAR allow them).
  Future<ArchiveEntry> addStream(
    ArchiveEntrySpec spec,
    Stream<Uint8List> content, {
    required int size,
  });

  /// Writes a file entry from in-memory [content] (sugar for [addStream]
  /// with the size known).
  Future<ArchiveEntry> addBytes(ArchiveEntrySpec spec, Uint8List content) =>
      addStream(spec, Stream<Uint8List>.value(content), size: content.length);

  /// Writes a metadata-only entry: a directory, symlink, hardlink, or other
  /// contentless type. Throws [ArgumentError] for a file-typed spec.
  Future<ArchiveEntry> addEntry(ArchiveEntrySpec spec);

  /// Finalizes the archive. Idempotent-safe to call once; further `add*`
  /// calls afterward throw [ArchiveClosedException]. Does not close the
  /// [ByteSink].
  Future<void> close();
}

/// Descriptor for one writable archive format (Phase 2): its name and how
/// to open a writer over a sink. Unlike reading there is no detection —
/// writing always names the format explicitly.
abstract class ArchiveWriteFormat {
  /// Const-constructable so descriptors can be compile-time constants.
  const ArchiveWriteFormat();

  /// Short lower-case format name (e.g. `tar`, `zip`).
  String get name;

  /// Opens a writer that appends to [sink] under [options]. Synchronous:
  /// opening a writer does no I/O (the sink is already open).
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options);
}
