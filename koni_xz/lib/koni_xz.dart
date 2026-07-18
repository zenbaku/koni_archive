/// XZ reader and writer for the koni_archive ecosystem: single-entry `.xz`
/// archives and layered `.tar.xz`.
///
/// Most applications use the `koni_archive` facade, which registers
/// [XzFormat] (read, auto-detected, with TAR layered so `.tar.xz` opens as the
/// inner TAR) and exposes [XzWriteFormat] (write) automatically. Depend on this
/// package directly only to build a custom format registry.
///
/// **Reading** supports the `.xz` container across any number of concatenated
/// streams, with the LZMA2 payload and the delta / BCJ (x86) transform filters,
/// and verifies the None / CRC-32 / CRC-64 / SHA-256 integrity checks. Decoded
/// block by block: a `.xz` written by default single-threaded `xz` is one
/// block, so a large file decodes one large buffer (multithreaded `xz -T0`
/// splits it). Typed errors: other BCJ variants (ARM/PPC/SPARC/…), a non-zero
/// BCJ start offset, and reserved check ids. `.xz` carries no filename or
/// timestamp, so the single entry is named from the container.
///
/// **Writing** ([XzWriteFormat]) compresses one byte stream with LZMA2 as a
/// single block with a CRC-64 check (`.xz` is a single-member container). It
/// has no encryption. The output is byte-decodable by `xz` / liblzma.
library;

export 'src/xz_format.dart';
export 'src/xz_reader.dart' show XzReader;
export 'src/xz_write_format.dart';
export 'src/xz_writer.dart' show XzWriter;
