import 'entry.dart';

/// Options honored by archive writers, passed through `Archive.create` /
/// `ArchiveWriteFormat.openWriter`.
final class ArchiveWriteOptions {
  /// Creates options; the defaults are what applications normally want.
  const ArchiveWriteOptions({
    this.compression,
    this.password,
    this.encryptHeader = false,
  });

  /// Default compression method for entries whose [ArchiveEntrySpec] does
  /// not specify one. `null` means "the format's own default" (stored for
  /// TAR, deflate for ZIP). A format that cannot honor the requested method
  /// throws [UnsupportedCompressionException] at write time.
  final ArchiveCompression? compression;

  /// Password to encrypt the archive with (Phase 4,
  /// `doc/encryption-scope.md`). `null` (the default) writes plaintext.
  ///
  /// When set, every entry's content is encrypted with **AES-256**: WinZip
  /// AES (AE-2, method 99) for ZIP, AES-256-CBC for 7z. Encryption is
  /// whole-archive: it is not selectable per entry, mirroring how a reader
  /// supplies one [password] for the whole archive. Formats without an
  /// encryption writer (TAR) reject a non-null password with
  /// [UnsupportedCompressionException]; the legacy zipcrypto and RAR schemes
  /// are read-only (`doc/encryption-scope.md`).
  ///
  /// Encoding is format-defined and handled internally, matching the read
  /// side: ZIP uses the UTF-8 bytes, 7z the UTF-16LE bytes. The
  /// authentication these schemes provide is documented on the writers; the
  /// [password]-derived keys are the same primitives the readers use and
  /// carry the same non-goals (not constant-time, no key zeroization).
  final String? password;

  /// Also encrypt the archive's header, hiding entry names and metadata
  /// (7z `-mhe`). Requires [password]; opening the archive then needs the
  /// password up front, not just to read an entry.
  ///
  /// **7z only.** WinZip AES (ZIP) never encrypts the central directory
  /// (filenames are always visible there), so the ZIP writer ignores this
  /// flag. TAR rejects any password outright. Setting it without a
  /// [password] is an error (there is nothing to encrypt the header with).
  final bool encryptHeader;
}
