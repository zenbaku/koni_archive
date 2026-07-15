import 'dart:typed_data';

/// Options honored by format readers, passed through `Archive.open` /
/// `ArchiveFormatRegistry.openReader`.
final class ArchiveReadOptions {
  /// Creates options; the defaults are what applications normally want.
  const ArchiveReadOptions({
    this.verifyChecksums = true,
    this.entryNameDecoder,
  });

  /// Verify content checksums recorded by the format (CRC-32 for ZIP and
  /// gzip) while streaming; a mismatch errors the stream at its end with a
  /// `ChecksumMismatchException` (§7). On by default; disable only for
  /// forensic reads of damaged archives.
  final bool verifyChecksums;

  /// Caller-supplied decoder for entry names whose encoding the format does
  /// not record reliably (§8) — ZIP entries *without* the UTF-8 flag are
  /// the classic case (manga archives from assorted tools are often
  /// Shift-JIS). When set, it receives the raw stored name bytes and its
  /// result replaces the default strict-UTF-8-then-CP437 heuristic. Names
  /// that declare UTF-8 (ZIP general-purpose bit 11) are decoded as UTF-8
  /// regardless. Exceptions thrown by the decoder propagate to the caller.
  final String Function(Uint8List nameBytes)? entryNameDecoder;
}
