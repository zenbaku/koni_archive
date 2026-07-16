/// Typed exception hierarchy for archive-content problems.
///
/// Every archive-content failure anywhere in the koni_archive ecosystem is an
/// [ArchiveException] subtype, never a bare [Exception], [StateError], or
/// [RangeError]. Each exception carries context (format, byte offset, entry
/// path) where known.
library;

/// Root of the typed exception hierarchy for archive-content problems.
///
/// Hierarchy:
///
/// - [ArchiveException]
///   - [UnsupportedFormatException]
///   - [CorruptArchiveException]
///     - [UnexpectedEofException]
///     - [InvalidHeaderException]
///     - [ChecksumMismatchException]
///   - [UnsupportedFeatureException]
///     - [UnsupportedCompressionException]
///   - [EncryptedArchiveException]
///     - [InvalidPasswordException]
///   - [SizeLimitExceededException]
///   - [ArchiveClosedException]
///   - [EntryNotFoundException]
class ArchiveException implements Exception {
  /// Creates an exception with a human-readable [message] and optional
  /// context.
  ArchiveException(this.message, {this.format, this.offset, this.entryPath});

  /// Human-readable description of the problem.
  final String message;

  /// Name of the archive format being parsed (e.g. `zip`), when known.
  final String? format;

  /// Byte offset into the archive where the problem was detected, when known.
  final int? offset;

  /// Normalized path of the entry the problem relates to, when applicable.
  final String? entryPath;

  @override
  String toString() {
    final context = [
      if (format != null) 'format: $format',
      if (offset != null) 'offset: $offset',
      if (entryPath != null) 'entry: $entryPath',
    ];
    final suffix = context.isEmpty ? '' : ' (${context.join(', ')})';
    // Note: runtimeType may be minified in dart2js production builds; the
    // message itself is always descriptive.
    return '$runtimeType: $message$suffix';
  }
}

/// No registered [format] matches the input, or the input is not an archive.
class UnsupportedFormatException extends ArchiveException {
  /// Creates an [UnsupportedFormatException].
  UnsupportedFormatException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}

/// The input matched a format but its structure is invalid.
class CorruptArchiveException extends ArchiveException {
  /// Creates a [CorruptArchiveException].
  CorruptArchiveException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}

/// The input ended before a structure that should be present was complete.
///
/// A form of corruption, so it extends [CorruptArchiveException]: truncated
/// archives are caught by `on CorruptArchiveException` as well.
class UnexpectedEofException extends CorruptArchiveException {
  /// Creates an [UnexpectedEofException].
  UnexpectedEofException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}

/// A header record is structurally invalid (bad magic, checksum, or field).
///
/// A form of corruption, so it extends [CorruptArchiveException].
class InvalidHeaderException extends CorruptArchiveException {
  /// Creates an [InvalidHeaderException].
  InvalidHeaderException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}

/// Decoded data does not match the checksum recorded in the archive.
///
/// A form of corruption, so it extends [CorruptArchiveException]. Streaming
/// reads verify at end-of-stream and emit this through the stream.
class ChecksumMismatchException extends CorruptArchiveException {
  /// Creates a [ChecksumMismatchException].
  ChecksumMismatchException(
    super.message, {
    this.expected,
    this.actual,
    super.format,
    super.offset,
    super.entryPath,
  });

  /// Checksum value recorded in the archive, when known.
  final int? expected;

  /// Checksum value computed over the decoded data, when known.
  final int? actual;
}

/// The archive uses a feature this implementation does not (yet) support
/// (e.g. ZIP64 before M7, GNU sparse tars, multi-volume archives).
class UnsupportedFeatureException extends ArchiveException {
  /// Creates an [UnsupportedFeatureException].
  UnsupportedFeatureException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}

/// An entry is compressed with a method this implementation does not
/// support. Always names the method (and raw id where the format records
/// one) so diagnostics can identify it.
class UnsupportedCompressionException extends UnsupportedFeatureException {
  /// Creates an [UnsupportedCompressionException].
  UnsupportedCompressionException(
    super.message, {
    this.methodName,
    this.methodId,
    super.format,
    super.offset,
    super.entryPath,
  });

  /// Human-readable name of the compression method, when known (e.g. `ppmd`).
  final String? methodName;

  /// Raw format-specific method id, when the format records one.
  final int? methodId;
}

/// The archive (or the requested entry) is encrypted and no password was
/// supplied, or it uses an encryption scheme this implementation does not
/// support (`doc/encryption-scope.md`, e.g. ZIP strong encryption, RAR4
/// encrypted headers).
class EncryptedArchiveException extends ArchiveException {
  /// Creates an [EncryptedArchiveException].
  EncryptedArchiveException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}

/// The supplied password failed the format's password check.
///
/// How reliably a wrong password is *distinguishable from corruption*
/// varies by format: RAR5 carries an 8-byte check value (practically
/// certain), WinZip AES a 2-byte verifier (1/65536 false accept),
/// zipcrypto a 1-byte check (1/256; a wrong password can also surface as
/// a [CorruptArchiveException] or [ChecksumMismatchException] instead),
/// and 7z has no check at all, so a wrong password there always surfaces
/// as corrupt data or a checksum mismatch, never as this exception.
class InvalidPasswordException extends EncryptedArchiveException {
  /// Creates an [InvalidPasswordException].
  InvalidPasswordException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}

/// Decoded output exceeded a caller-supplied or format-derived size limit
/// (decompression-bomb protection).
class SizeLimitExceededException extends ArchiveException {
  /// Creates a [SizeLimitExceededException].
  SizeLimitExceededException(
    super.message, {
    this.limit,
    super.format,
    super.offset,
    super.entryPath,
  });

  /// The limit, in bytes, that was exceeded, when known.
  final int? limit;
}

/// An operation was attempted on an archive or byte source that has been
/// closed, or `close()` cancelled an in-flight read.
class ArchiveClosedException extends ArchiveException {
  /// Creates an [ArchiveClosedException].
  ArchiveClosedException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}

/// A path-based lookup did not match any entry (e.g. `openReadPath` on an
/// absent path).
class EntryNotFoundException extends ArchiveException {
  /// Creates an [EntryNotFoundException].
  EntryNotFoundException(
    super.message, {
    super.format,
    super.offset,
    super.entryPath,
  });
}
