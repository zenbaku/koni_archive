import 'package:koni_archive_core/koni_archive_core.dart';

import 'zstd_decompressed_source.dart';
import 'zstd_reader.dart';

/// The Zstandard format: a bare `.zst` opens as a **single-entry archive**
/// (name derived from the source name — `.zst` stores none), and, when
/// [layeredFormats] are given, a compressed container whose decompressed head
/// sniffs as one of them (`.tar.zst`) presents as the *inner* archive. Register
/// into an `ArchiveFormatRegistry` (the koni_archive facade does this for you,
/// with TAR layered).
final class ZstdFormat extends ArchiveFormat {
  /// Creates the format descriptor.
  ///
  /// [layeredFormats] are probed (in order) against the *decompressed* content
  /// through a [ZstdDecompressedByteSource]; the first match reads the inner
  /// archive. The decompressed source decodes the whole container at open (zstd
  /// may omit the content size), so only head-sniffing formats such as TAR
  /// belong here.
  const ZstdFormat({this.layeredFormats = const []});

  /// Formats to probe against the decompressed content (layering).
  final List<ArchiveFormat> layeredFormats;

  @override
  String get name => 'zstd';

  /// Detection: the Zstandard frame magic `28 B5 2F FD`, or a skippable-frame
  /// magic `50..5F 2A 4D 18` (a `.zst` may lead with a skippable frame).
  @override
  Future<bool> matches(ByteSource source) async {
    if (source.length < 4) return false;
    final head = await source.read(0, 4);
    final magic = head[0] | (head[1] << 8) | (head[2] << 16) | (head[3] << 24);
    return magic == 0xFD2FB528 || (magic & 0xFFFFFFF0) == 0x184D2A50;
  }

  @override
  Future<ArchiveReader> createReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    if (layeredFormats.isNotEmpty) {
      final decompressed = await ZstdDecompressedByteSource.open(
        source,
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
      await decompressed.close();
    }
    return ZstdReader.parse(this, source, options);
  }
}
