/// Pure Dart compression codecs as synchronous chunked converters, usable
/// standalone with no archive knowledge.
///
/// Available codecs: [InflateDecoder] (raw DEFLATE, RFC 1951), [GzipDecoder]
/// (gzip framing incl. multi-member, RFC 1952), [LzmaDecoder]/[Lzma2Decoder]
/// (7z and xz), [Bzip2Decoder] (bzip2, `BZh1`–`BZh9`), and [ZstdDecoder]
/// (Zstandard, RFC 8878), plus the resumable engines ([RawInflater],
/// [RawGzipDecoder], [RawBzip2Decoder], [RawZstdDecoder]) for framing layers.
/// On malformed input, everything in this package throws
/// [FormatException]; the archive layer translates that into its typed
/// exception hierarchy.
///
/// Encoders: [DeflateEncoder], [LzmaEncoder]/[Lzma2Encoder], [Bzip2Encoder],
/// and [ZstdEncoder] (LZ sequences over the predefined FSE tables with raw
/// literals; output is decodable by `zstd`).
///
/// Cryptographic primitives (AES, SHA, HMAC, PBKDF2; Phase 3) live in the
/// separate `package:koni_codecs/crypto.dart` entrypoint.
library;

export 'src/bit_reader.dart';
export 'src/bzip2.dart';
export 'src/bzip2_encoder.dart';
export 'src/deflate.dart';
export 'src/filters.dart';
export 'src/gzip.dart';
export 'src/inflate.dart';
export 'src/lzma.dart';
export 'src/lzma2.dart';
export 'src/lzma2_encoder.dart';
export 'src/lzma_encoder.dart';
export 'src/zstd.dart';
export 'src/zstd_encoder.dart';
