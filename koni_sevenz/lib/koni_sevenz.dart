/// 7z reader for the koni_archive ecosystem, including CB7 comic archives.
///
/// Most applications use the `koni_archive` facade, which registers
/// [SevenZFormat] automatically. Depend on this package directly only to
/// build a custom format registry.
///
/// Supported codec chains: Copy, LZMA, LZMA2, Deflate, with Delta and
/// BCJ (x86) filters; solid blocks are cached in a size-capped LRU so CB7
/// page-flipping stays fast (§8). AES-256-encrypted archives — streams and
/// headers alike — decrypt via `ArchiveReadOptions.password` (P3-3).
/// Detected with typed errors: BCJ2, PPMd, bzip2, multi-volume. Note the
/// §4 caveat: the 7z header block is itself usually LZMA-compressed (and,
/// with `-mhe`, AES-encrypted), so opening decodes it.
library;

export 'src/sevenz_format.dart';
export 'src/sevenz_reader.dart' show SevenZReader;
export 'src/sevenz_write_format.dart';
export 'src/sevenz_writer.dart' show SevenZWriter;
