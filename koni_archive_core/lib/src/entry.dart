/// What kind of filesystem object an archive entry represents.
///
/// Exotic types (symlinks, hardlinks, FIFOs, devices) are *represented* as
/// metadata, never materialized or followed.
enum ArchiveEntryType {
  /// A regular file.
  file,

  /// A directory.
  directory,

  /// A symbolic link; the target is in [ArchiveEntry.linkTarget].
  symlink,

  /// A hard link; the target is in [ArchiveEntry.linkTarget].
  hardlink,

  /// A FIFO (named pipe).
  fifo,

  /// A character device node.
  characterDevice,

  /// A block device node.
  blockDevice,

  /// Any other type the source format records.
  other,
}

/// The compression method an entry's content is stored with.
///
/// A small open set: well-known methods are exposed as constants, and any
/// method this library does not recognize is [ArchiveCompression.unknown]
/// with the raw format-specific id preserved so diagnostics can name it.
/// Whether content is compressed at all is derivable: everything
/// except [stored] is.
final class ArchiveCompression {
  const ArchiveCompression._(this.name) : rawId = null;

  /// An unrecognized method with the format's raw method id (e.g. a ZIP
  /// method id this library has no decoder for).
  const ArchiveCompression.unknown(int this.rawId) : name = 'unknown';

  /// Lower-case method name (`stored`, `deflate`, …, or `unknown`).
  final String name;

  /// The raw format-specific method id; non-null only for
  /// [ArchiveCompression.unknown] values.
  final int? rawId;

  /// Content is stored without compression.
  static const ArchiveCompression stored = ArchiveCompression._('stored');

  /// DEFLATE (RFC 1951): ZIP method 8, gzip.
  static const ArchiveCompression deflate = ArchiveCompression._('deflate');

  /// LZMA: 7z's primary codec.
  static const ArchiveCompression lzma = ArchiveCompression._('lzma');

  /// LZMA2: chunked LZMA, used by 7z and xz.
  static const ArchiveCompression lzma2 = ArchiveCompression._('lzma2');

  /// Deflate64 (enhanced deflate): ZIP method 9.
  static const ArchiveCompression deflate64 = ArchiveCompression._('deflate64');

  /// bzip2: ZIP method 12.
  static const ArchiveCompression bzip2 = ArchiveCompression._('bzip2');

  /// PPMd: ZIP method 98, 7z codec.
  static const ArchiveCompression ppmd = ArchiveCompression._('ppmd');

  /// Zstandard: ZIP method 93.
  static const ArchiveCompression zstd = ArchiveCompression._('zstd');

  @override
  bool operator ==(Object other) =>
      other is ArchiveCompression && other.name == name && other.rawId == rawId;

  @override
  int get hashCode => Object.hash(name, rawId);

  @override
  String toString() =>
      rawId == null ? name : '$name(0x${rawId!.toRadixString(16)})';
}

/// One entry of an archive, deeply immutable and isolate-transferable.
///
/// [path] is always normalized at parse time: `/` separators, no drive
/// letters, no leading `/`, no `.`/`..` segments, no trailing `/`. Paths
/// that attempted to escape the archive root are sanitized and flagged via
/// [pathEscapedRoot], never exposed raw, never dropped silently.
final class ArchiveEntry {
  /// Creates an entry. [modified], when given, must be UTC.
  ArchiveEntry({
    required this.path,
    required this.type,
    required this.uncompressedSize,
    this.compression = ArchiveCompression.stored,
    this.compressedSize,
    this.modified,
    this.linkTarget,
    this.posixMode,
    this.crc32,
    this.isEncrypted = false,
    this.pathEscapedRoot = false,
  }) : assert(
         modified == null || modified.isUtc,
         'modified must be UTC; readers normalize at parse time',
       );

  /// Normalized entry path (see class docs). May be empty for entries that
  /// denote the archive root (e.g. a bare `/` directory entry).
  final String path;

  /// What kind of object this entry represents.
  final ArchiveEntryType type;

  /// Size of the stored (compressed) content in bytes, or null where the
  /// format does not record it (TAR).
  final int? compressedSize;

  /// Size of the content after decompression, in bytes.
  final int uncompressedSize;

  /// Last-modified timestamp in UTC, or null where the format does not
  /// record one. Precision varies by format (documented per format, e.g.
  /// ZIP DOS timestamps have 2-second resolution and no zone).
  final DateTime? modified;

  /// Compression method of the content.
  final ArchiveCompression compression;

  /// Link target for [ArchiveEntryType.symlink] / [ArchiveEntryType.hardlink]
  /// entries. Metadata only, never followed.
  final String? linkTarget;

  /// POSIX permission bits, when the format records them.
  final int? posixMode;

  /// CRC-32 of the uncompressed content, when the format records one.
  final int? crc32;

  /// Whether the entry's content is encrypted (Phase 1 detects, never
  /// decrypts; reading such an entry throws a typed error).
  final bool isEncrypted;

  /// True when the path stored in the archive attempted to escape the
  /// archive root (via `..`) and was sanitized.
  final bool pathEscapedRoot;

  /// Whether this entry is a regular file.
  bool get isFile => type == ArchiveEntryType.file;

  /// Whether this entry is a directory.
  bool get isDirectory => type == ArchiveEntryType.directory;

  @override
  String toString() =>
      'ArchiveEntry(${type.name} $path, $uncompressedSize B, '
      '$compression${isEncrypted ? ', encrypted' : ''})';
}
