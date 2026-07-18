/// Zstandard reader for the koni_archive ecosystem: single-entry `.zst`
/// archives and layered `.tar.zst`.
///
/// Most applications use the `koni_archive` facade, which registers
/// [ZstdFormat] automatically (with TAR layered, so `.tar.zst` opens as the
/// inner TAR). Depend on this package directly only to build a custom format
/// registry.
///
/// Decodes the Zstandard format (RFC 8878) via `koni_codecs`, one block at a
/// time so memory stays bounded; concatenated frames and skippable frames are
/// handled, and the XXH64 content checksum is verified on platforms with native
/// 64-bit integers (skipped under dart2js/dart2wasm). `.zst` carries no filename
/// and may omit the decompressed size, so the single entry is named from the
/// container and its `uncompressedSize` is `-1` (unknown). Typed errors:
/// dictionary-compressed frames and the legacy (v0.x) formats. The same codec
/// also decodes zstd inside ZIP (method 93), in `koni_zip`.
library;

export 'src/zstd_format.dart';
export 'src/zstd_reader.dart' show ZstdReader;
