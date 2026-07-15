import 'package:koni_archive_core/koni_archive_core.dart';

import 'header.dart';
import 'tar_reader.dart';

/// The TAR archive format (POSIX ustar, PAX, GNU; also `.cbt` comic
/// archives). Register into an `ArchiveFormatRegistry` (the koni_archive
/// facade does this for you).
final class TarFormat extends ArchiveFormat {
  /// Creates the format descriptor. Stateless and const.
  const TarFormat();

  @override
  String get name => 'tar';

  /// TAR detection facts (§5): `ustar` magic at offset 257; pre-POSIX v7
  /// tars have no magic — fall back to validating block 0's header
  /// checksum. An all-zero leading block is accepted as an empty archive
  /// (what `tar -cf x.tar -T /dev/null` produces; matches bsdtar).
  @override
  Future<bool> matches(ByteSource source) async {
    if (source.length < tarBlockSize) return false;
    final block = await source.read(0, tarBlockSize);

    // 'ustar' at offset 257 covers POSIX ustar/PAX and old-GNU.
    if (block[257] == 0x75 &&
        block[258] == 0x73 &&
        block[259] == 0x74 &&
        block[260] == 0x61 &&
        block[261] == 0x72) {
      return true;
    }

    var allZero = true;
    for (final byte in block) {
      if (byte != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) return source.length % tarBlockSize == 0;

    return TarHeader.checksumLooksValid(block);
  }

  // TAR has no content checksums, so [options] has nothing to control yet.
  @override
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) => TarReader.parse(this, source);
}
