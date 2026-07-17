import 'dart:typed_data';

import 'byte_source.dart';

/// Options honored by format readers, passed through `Archive.open` /
/// `ArchiveFormatRegistry.openReader`.
final class ArchiveReadOptions {
  /// Creates options; the defaults are what applications normally want.
  const ArchiveReadOptions({
    this.verifyChecksums = true,
    this.entryNameDecoder,
    this.password,
    this.nextVolume,
    this.maxEntrySize,
    this.maxEntryCount,
    this.maxContainerDecodeSize,
  });

  /// Verify content checksums recorded by the format (CRC-32 for ZIP and
  /// gzip) while streaming; a mismatch errors the stream at its end with a
  /// `ChecksumMismatchException`. On by default; disable only for
  /// forensic reads of damaged archives.
  final bool verifyChecksums;

  /// Caller-supplied decoder for entry names whose encoding the format does
  /// not record reliably: ZIP entries *without* the UTF-8 flag are
  /// the classic case (manga archives from assorted tools are often
  /// Shift-JIS). When set, it receives the raw stored name bytes and its
  /// result replaces the default strict-UTF-8-then-CP437 heuristic. Names
  /// that declare UTF-8 (ZIP general-purpose bit 11) are decoded as UTF-8
  /// regardless. Exceptions thrown by the decoder propagate to the caller.
  final String Function(Uint8List nameBytes)? entryNameDecoder;

  /// Password for encrypted archives (Phase 3, `doc/encryption-scope.md`).
  ///
  /// Used lazily: an encrypted *entry* only needs it at `openRead`, while
  /// encrypted *headers* (7z `-mhe`, RAR5 `-hp`) need it at open. Reading
  /// an encrypted entry without a password throws
  /// `EncryptedArchiveException`; a wrong password throws
  /// `InvalidPasswordException` where the format carries a password check
  /// (see that exception for per-format reliability) and may otherwise
  /// surface as corrupt data or a checksum mismatch.
  ///
  /// Encoding is format-defined and handled internally: ZIP and RAR5 use
  /// the UTF-8 bytes, 7z and RAR4 the UTF-16LE bytes. Legacy zipcrypto
  /// archives authored with a non-ASCII OEM-codepage password may not
  /// match their UTF-8 encoding, documented lossiness, same spirit as
  /// entry-name encodings.
  final String? password;

  /// Resolver for the later parts of a **multi-volume** archive (a set split
  /// across `name.part1.rar`, `name.part2.rar`, … or `name.rar`, `name.r00`,
  /// …). Volume 1 is the source passed to the reader; the reader calls this
  /// with the 1-based number of each subsequent volume it needs (2, 3, …) and
  /// expects that volume's [ByteSource], or null when there is no such volume.
  ///
  /// Opening a multi-volume archive without a resolver (or one that returns
  /// null while a file's data still continues into a further volume) is a
  /// typed error (`UnsupportedFeatureException` / `UnexpectedEofException`),
  /// never a silent truncation. Single-volume archives never call it. The
  /// reader does not close the volumes it obtains this way; the caller owns
  /// their lifetime, as with the volume-1 source.
  final Future<ByteSource?> Function(int volume)? nextVolume;

  /// Maximum decoded size, in bytes, of any single entry
  /// (decompression-bomb protection). Null (the default) means unbounded.
  ///
  /// When set, streaming an entry whose decoded output grows past this many
  /// bytes aborts the decode and throws `SizeLimitExceededException`. It is
  /// enforced uniformly for every format at the `ArchiveFormat.openReader`
  /// seam, so it holds whether you go through the `Archive` facade or a
  /// format's reader directly. `Archive.readBytes`'s own `maxSize` still
  /// applies as an additional, possibly tighter, per-call bound.
  ///
  /// This is a *per-entry* limit. For a layered `.tar.gz` it additionally
  /// serves as the default cap on the open-time container decode (which
  /// [maxContainerDecodeSize] overrides), so setting only this option still
  /// protects against a gzip bomb at open. It does **not** bound 7z's
  /// header/solid-folder decodes — those are opt-in via
  /// [maxContainerDecodeSize] — so a per-entry limit never rejects a small
  /// entry that merely lives in a larger solid folder.
  final int? maxEntrySize;

  /// Maximum decoded size, in bytes, of a single **bulk/auxiliary decode** a
  /// reader performs that is not a per-entry `openRead` stream
  /// (decompression-bomb protection for the decodes [maxEntrySize] cannot
  /// see). Null (the default) leaves each format at its built-in behavior.
  ///
  /// It bounds the formats that buffer a decode larger than one entry:
  ///
  /// - **Layered gzip (`.tar.gz`)**: the whole container is decompressed at
  ///   open to enumerate the inner archive. A container that decompresses past
  ///   this limit is rejected at open with `SizeLimitExceededException`
  ///   (checked against the gzip trailer, before any bytes are decoded). When
  ///   this is null it **falls back to [maxEntrySize]** for that open-time
  ///   decode — the container is a one-time open cost, so a caller who set only
  ///   a per-entry limit stays protected; both null leaves it unbounded.
  /// - **7z**: the (possibly compressed) header and each solid folder are
  ///   decoded as a unit — reading one small entry can decode a whole large
  ///   folder. This limit caps both, tightening 7z's built-in backstops
  ///   (64 MiB header, 1 GiB folder). Unlike gzip it does **not** fall back to
  ///   [maxEntrySize] (which would reject a small entry buried in a larger
  ///   solid folder); the backstops apply when this is null.
  ///
  /// It is a **no-op** for formats that open on stored metadata and stream
  /// each entry — ZIP, plain (uncompressed) TAR, and plain single-member gzip
  /// — for which [maxEntrySize] is the relevant limit. **RAR does not yet
  /// enforce it**: a solid RAR run decodes from the run start to reach a later
  /// entry, an amplification this option is meant to cover, but that path is
  /// not wired to it (a documented gap; [maxEntrySize] still bounds each
  /// entry's own decoded output).
  final int? maxContainerDecodeSize;

  /// Maximum number of entries an archive may declare (directory-bomb
  /// protection). Null (the default) means unbounded.
  ///
  /// When set, opening an archive that declares more entries than this throws
  /// `SizeLimitExceededException`. Readers that learn the count up front
  /// (ZIP's end-of-central-directory total, 7z's file count) reject before
  /// allocating the entry index; the limit is otherwise enforced once the
  /// index is built, which still rejects the archive but after the parse has
  /// already run. Enforced at the same `ArchiveFormat.openReader` seam as
  /// [maxEntrySize].
  final int? maxEntryCount;
}
