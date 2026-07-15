/// Pure Dart compression codecs as synchronous chunked converters, usable
/// standalone with no archive knowledge (§6.4).
///
/// Available codecs: [InflateDecoder] (raw DEFLATE, RFC 1951) and
/// [GzipDecoder] (gzip framing incl. multi-member, RFC 1952), plus the
/// resumable engines ([RawInflater], [RawGzipDecoder]) for framing layers.
/// More codecs land milestone by milestone (LZMA at M8, …). On malformed
/// input, everything in this package throws [FormatException] — the archive
/// layer translates that into its typed exception hierarchy.
///
/// Cryptographic primitives (AES, SHA, HMAC, PBKDF2 — Phase 3) live in the
/// separate `package:koni_codecs/crypto.dart` entrypoint.
library;

export 'src/bit_reader.dart';
export 'src/deflate.dart';
export 'src/filters.dart';
export 'src/gzip.dart';
export 'src/inflate.dart';
export 'src/lzma.dart';
export 'src/lzma2.dart';
export 'src/lzma2_encoder.dart';
export 'src/lzma_encoder.dart';
