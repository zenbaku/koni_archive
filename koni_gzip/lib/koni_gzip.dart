/// GZIP adapter for the koni_archive ecosystem: single-entry `.gz` archives
/// and layered `.tar.gz` handling via [GzipDecompressedByteSource].
///
/// Most applications use the `koni_archive` facade, which registers
/// [GzipFormat] automatically. A bare `.gz` opens as a single-entry archive:
/// name from the FNAME field, else derived from the source name.
/// Multi-member (concatenated) files decode as one concatenated stream,
/// with each member's CRC-32/ISIZE verified by default.
library;

export 'src/decompressed_source.dart';
export 'src/gzip_format.dart';
export 'src/gzip_reader.dart' show GzipReader;
