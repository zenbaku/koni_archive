import 'package:koni_archive_core/koni_archive_core.dart';

import 'xz_container.dart';
import 'xz_decompressed_source.dart';
import 'xz_reader.dart';

/// The xz format: a bare `.xz` opens as a **single-entry archive** (name
/// derived from the source name — `.xz` stores none), and, when
/// [layeredFormats] are given, a compressed container whose decompressed head
/// sniffs as one of them (`.tar.xz`) presents as the *inner* archive. Register
/// into an `ArchiveFormatRegistry` (the koni_archive facade does this for you,
/// with TAR layered).
final class XzFormat extends ArchiveFormat {
  /// Creates the format descriptor.
  ///
  /// [layeredFormats] are probed (in order) against the *decompressed* content;
  /// the first match reads the inner archive through an
  /// [XzDecompressedByteSource] (block-by-block decode + in-memory cache, see
  /// its docs for the cost model). Only head-sniffing formats such as TAR
  /// belong here.
  const XzFormat({this.layeredFormats = const []});

  /// Formats to probe against the decompressed content (layering).
  final List<ArchiveFormat> layeredFormats;

  @override
  String get name => 'xz';

  /// Detection: the six-byte `.xz` stream-header magic `FD 37 7A 58 5A 00`.
  @override
  Future<bool> matches(ByteSource source) async {
    if (source.length < 12) return false;
    final head = await source.read(0, 6);
    for (var i = 0; i < 6; i++) {
      if (head[i] != xzMagic[i]) return false;
    }
    return true;
  }

  @override
  Future<ArchiveReader> createReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    if (layeredFormats.isNotEmpty) {
      final decompressed = await XzDecompressedByteSource.open(
        source,
        verifyChecksums: options.verifyChecksums,
        // Like layered gzip, the container decode is an open-time cost, so a
        // caller who set only `maxEntrySize` is still protected; an explicit
        // `maxContainerDecodeSize` overrides.
        maxDecodedSize: options.maxContainerDecodeSize ?? options.maxEntrySize,
      );
      for (final inner in layeredFormats) {
        try {
          if (await inner.matches(decompressed)) {
            return inner.openReader(decompressed, options);
          }
        } on ArchiveException {
          continue; // probe over-read or similar: not this format
        }
      }
      // Nothing matched: fall through to the single-entry adapter.
      await decompressed.close();
    }
    return XzReader.parse(this, source, options);
  }
}
