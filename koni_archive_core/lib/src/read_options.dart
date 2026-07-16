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
  /// match their UTF-8 encoding — documented lossiness, same spirit as
  /// entry-name encodings (§8).
  final String? password;

  /// Resolver for the later parts of a **multi-volume** archive (a set split
  /// across `name.part1.rar`, `name.part2.rar`, … or `name.rar`, `name.r00`,
  /// …). Volume 1 is the source passed to the reader; the reader calls this
  /// with the 1-based number of each subsequent volume it needs (2, 3, …) and
  /// expects that volume's [ByteSource], or null when there is no such volume.
  ///
  /// Opening a multi-volume archive without a resolver — or one that returns
  /// null while a file's data still continues into a further volume — is a
  /// typed error (`UnsupportedFeatureException` / `UnexpectedEofException`),
  /// never a silent truncation. Single-volume archives never call it. The
  /// reader does not close the volumes it obtains this way; the caller owns
  /// their lifetime, as with the volume-1 source.
  final Future<ByteSource?> Function(int volume)? nextVolume;
}
