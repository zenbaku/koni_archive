/// BZip2 reader for the koni_archive ecosystem: single-entry `.bz2` archives
/// and layered `.tar.bz2`.
///
/// Most applications use the `koni_archive` facade, which registers
/// [Bzip2Format] automatically (with TAR layered, so `.tar.bz2` opens as the
/// inner TAR). Depend on this package directly only to build a custom format
/// registry.
///
/// Decodes the bzip2 format (`BZh1`–`BZh9`) via `koni_codecs`, one block at a
/// time so memory stays bounded. Streams may be concatenated. `.bz2` carries no
/// filename, timestamp, or decompressed size, so the single entry is named from
/// the container and its `uncompressedSize` is `-1` (unknown). Randomized blocks
/// (a deprecated pre-0.9 bzip2 feature) are a typed error.
library;

export 'src/bzip2_format.dart';
export 'src/bzip2_reader.dart' show Bzip2Reader;
