/// BZip2 reader and writer for the koni_archive ecosystem: single-entry `.bz2`
/// archives and layered `.tar.bz2`.
///
/// Most applications use the `koni_archive` facade, which registers
/// [Bzip2Format] (read, auto-detected, with TAR layered so `.tar.bz2` opens as
/// the inner TAR) and exposes [Bzip2WriteFormat] (write) automatically. Depend
/// on this package directly only to build a custom format registry.
///
/// **Reading** decodes the bzip2 format (`BZh1`–`BZh9`) via `koni_codecs`, one
/// block at a time so memory stays bounded. Streams may be concatenated. `.bz2`
/// carries no filename, timestamp, or decompressed size, so the single entry is
/// named from the container and its `uncompressedSize` is `-1` (unknown).
/// Randomized blocks (a deprecated pre-0.9 bzip2 feature) are a typed error.
///
/// **Writing** ([Bzip2WriteFormat]) compresses one byte stream with bzip2
/// (RLE1 → Burrows–Wheeler transform → MTF/RLE2 → Huffman) at a configurable
/// block size (`bzip2 -1`..`-9`). It has no encryption. The output is
/// byte-decodable by `bzip2` / libbz2.
library;

export 'src/bzip2_format.dart';
export 'src/bzip2_reader.dart' show Bzip2Reader;
export 'src/bzip2_write_format.dart';
export 'src/bzip2_writer.dart' show Bzip2Writer;
