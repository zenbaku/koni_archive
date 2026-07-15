import 'dart:convert';
import 'dart:typed_data';

import 'inflate.dart';

/// gzip (RFC 1952) decompression as a synchronous, chunk-driven state
/// machine (§6.4), including **multi-member** files (concatenated streams,
/// §8). Malformed input throws [FormatException]; the archive layer
/// translates.
///
/// Trailer CRC-32 and ISIZE are verified per member by default
/// ([verifyChecksums]). Trailing bytes after the last member that do not
/// start with the gzip magic are ignored, matching gzip(1).
final class GzipDecoder extends Converter<List<int>, List<int>> {
  /// Creates the decoder. [onMemberHeader] is invoked with each member's
  /// parsed header (FNAME etc.) as decoding reaches it.
  const GzipDecoder({this.verifyChecksums = true, this.onMemberHeader});

  /// Verify each member's CRC-32 and ISIZE trailer (on by default).
  final bool verifyChecksums;

  /// Callback receiving each member's header metadata.
  final void Function(GzipMemberHeader header)? onMemberHeader;

  /// Decompresses a complete gzip file (all members, concatenated output).
  @override
  Uint8List convert(List<int> input) {
    final out = BytesBuilder(copy: false);
    final decoder = RawGzipDecoder(
      onOutput: out.add,
      verifyChecksums: verifyChecksums,
      onMemberHeader: onMemberHeader,
    );
    decoder.addInput(input is Uint8List ? input : Uint8List.fromList(input));
    decoder.finish();
    return out.takeBytes();
  }

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _GzipSink(sink, this);
}

final class _GzipSink implements ByteConversionSink {
  _GzipSink(this._downstream, GzipDecoder decoder)
    : _decoder = RawGzipDecoder(
        onOutput: _downstream.add,
        verifyChecksums: decoder.verifyChecksums,
        onMemberHeader: decoder.onMemberHeader,
      );

  final Sink<List<int>> _downstream;
  final RawGzipDecoder _decoder;

  @override
  void add(List<int> chunk) {
    _decoder.addInput(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(chunk.sublist(start, end));
    if (isLast) close();
  }

  @override
  void close() {
    _decoder.finish();
    _downstream.close();
  }
}

/// Parsed metadata of one gzip member header (RFC 1952).
final class GzipMemberHeader {
  /// Creates a header description.
  const GzipMemberHeader({
    this.fileName,
    this.comment,
    this.modified,
    this.isText = false,
  });

  /// Original file name (FNAME field, Latin-1), when recorded.
  final String? fileName;

  /// File comment (FCOMMENT field, Latin-1), when recorded.
  final String? comment;

  /// Modification time (MTIME field), UTC, when recorded (nonzero).
  final DateTime? modified;

  /// The FTEXT hint flag.
  final bool isText;
}

/// Attempts to parse a gzip member header at the start of [bytes].
///
/// Returns the header and its byte length, or null when [bytes] is too
/// short to decide (feed more input). Throws [FormatException] for input
/// that can never be a valid gzip header. When [verifyHeaderCrc] is set,
/// an FHCRC field is checked.
(GzipMemberHeader, int)? tryParseGzipHeader(
  Uint8List bytes, {
  bool verifyHeaderCrc = true,
}) {
  if (bytes.length < 10) return null;
  if (bytes[0] != 0x1F || bytes[1] != 0x8B) {
    throw const FormatException('not a gzip stream (bad magic)');
  }
  if (bytes[2] != 8) {
    throw FormatException('unsupported gzip compression method ${bytes[2]}');
  }
  final flags = bytes[3];
  if (flags & 0xE0 != 0) {
    throw const FormatException('reserved gzip flag bits set');
  }
  final mtimeSeconds =
      bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24);
  var pos = 10;

  if (flags & 0x04 != 0) {
    // FEXTRA
    if (bytes.length < pos + 2) return null;
    final xlen = bytes[pos] | (bytes[pos + 1] << 8);
    pos += 2;
    if (bytes.length < pos + xlen) return null;
    pos += xlen;
  }

  String? readZeroTerminated() {
    final start = pos;
    while (pos < bytes.length) {
      if (bytes[pos++] == 0) {
        return latin1.decode(Uint8List.sublistView(bytes, start, pos - 1));
      }
    }
    return null; // NUL not reached yet
  }

  String? fileName;
  if (flags & 0x08 != 0) {
    fileName = readZeroTerminated();
    if (fileName == null) return null;
  }
  String? comment;
  if (flags & 0x10 != 0) {
    comment = readZeroTerminated();
    if (comment == null) return null;
  }
  if (flags & 0x02 != 0) {
    // FHCRC: low 16 bits of the CRC-32 of the header bytes so far.
    if (bytes.length < pos + 2) return null;
    final stored = bytes[pos] | (bytes[pos + 1] << 8);
    if (verifyHeaderCrc) {
      final actual = crc32OfSlice(bytes, 0, pos) & 0xFFFF;
      if (stored != actual) {
        throw const FormatException('gzip header CRC mismatch');
      }
    }
    pos += 2;
  }

  return (
    GzipMemberHeader(
      fileName: fileName,
      comment: comment,
      modified:
          mtimeSeconds == 0
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                mtimeSeconds * 1000,
                isUtc: true,
              ),
      isText: flags & 0x01 != 0,
    ),
    pos,
  );
}

/// Resumable multi-member gzip decoder — the engine under [GzipDecoder],
/// public for the archive layer (koni_gzip), which needs chunk-driven
/// decoding with per-member metadata.
final class RawGzipDecoder {
  /// Creates a decoder delivering decoded chunks to [onOutput].
  RawGzipDecoder({
    required this.onOutput,
    this.verifyChecksums = true,
    this.onMemberHeader,
  });

  /// Receives each decoded chunk (ownership transfers).
  final void Function(Uint8List chunk) onOutput;

  /// Verify each member's CRC-32 and ISIZE trailer.
  final bool verifyChecksums;

  /// Callback receiving each member's header metadata.
  final void Function(GzipMemberHeader header)? onMemberHeader;

  /// Sanity cap on a member header (FEXTRA/FNAME/FCOMMENT are
  /// variable-length and attacker-controlled, §7).
  static const int _maxHeaderSize = 1024 * 1024;

  _GzState _state = _GzState.header;
  final BytesBuilder _headerBuf = BytesBuilder(copy: true);
  RawInflater? _inflater;
  final Uint8List _trailer = Uint8List(8);
  int _trailerFilled = 0;
  Uint8List _carry = Uint8List(0);
  int _members = 0;

  int _memberCrc = 0xFFFFFFFF;
  int _memberSize = 0;
  int _totalOut = 0;

  /// Total decoded bytes across all members so far.
  int get totalOut => _totalOut;

  /// Number of members fully decoded so far.
  int get membersDecoded => _members;

  /// Whether at least one member completed and no further member is in
  /// progress (more input could still start a new member).
  bool get isAtMemberBoundary =>
      _members > 0 &&
      (_state == _GzState.boundary || _state == _GzState.garbage);

  /// Consumes all of [chunk]. Throws [FormatException] on corruption.
  void addInput(Uint8List chunk) {
    var data = chunk;
    if (_carry.isNotEmpty) {
      data =
          Uint8List(_carry.length + chunk.length)
            ..setRange(0, _carry.length, _carry)
            ..setRange(_carry.length, _carry.length + chunk.length, chunk);
      _carry = Uint8List(0);
    }
    var pos = 0;
    while (pos < data.length) {
      switch (_state) {
        case _GzState.header:
          _headerBuf.add(Uint8List.sublistView(data, pos));
          pos = data.length;
          if (_headerBuf.length > _maxHeaderSize) {
            throw const FormatException('gzip header implausibly large');
          }
          final buffered = _headerBuf.toBytes();
          final parsed = tryParseGzipHeader(
            buffered,
            verifyHeaderCrc: verifyChecksums,
          );
          if (parsed == null) break; // need more input
          final (header, headerLength) = parsed;
          onMemberHeader?.call(header);
          _headerBuf.clear();
          _startMemberBody();
          // Re-process what followed the header in this buffered data.
          data = buffered;
          pos = headerLength;

        case _GzState.body:
          final inflater = _inflater!;
          pos += inflater.addInput(Uint8List.sublistView(data, pos));
          if (!inflater.isFinished) break; // consumed everything
          final leftovers = inflater.takeLeftoverBytes();
          if (leftovers.isNotEmpty) {
            final rest = Uint8List.sublistView(data, pos);
            data =
                Uint8List(leftovers.length + rest.length)
                  ..setRange(0, leftovers.length, leftovers)
                  ..setRange(
                    leftovers.length,
                    leftovers.length + rest.length,
                    rest,
                  );
            pos = 0;
          }
          _inflater = null;
          _trailerFilled = 0;
          _state = _GzState.trailer;

        case _GzState.trailer:
          while (_trailerFilled < 8 && pos < data.length) {
            _trailer[_trailerFilled++] = data[pos++];
          }
          if (_trailerFilled < 8) break;
          _checkTrailer();
          _members++;
          _state = _GzState.boundary;

        case _GzState.boundary:
          if (data.length - pos == 1 && data[pos] == 0x1F) {
            // Cannot decide with one byte; carry it to the next chunk.
            _carry = Uint8List.fromList([0x1F]);
            pos = data.length;
            break;
          }
          if (data[pos] == 0x1F && data[pos + 1] == 0x8B) {
            _state = _GzState.header; // next member
          } else {
            // Trailing non-gzip bytes: ignored, like gzip(1).
            _state = _GzState.garbage;
          }

        case _GzState.garbage:
          pos = data.length;
      }
    }
  }

  /// Declares end of input. Throws [FormatException] when a member is
  /// incomplete (or no member was ever present).
  void finish() {
    if (_carry.isNotEmpty) {
      // A lone 0x1F at EOF: trailing garbage.
      _carry = Uint8List(0);
      if (_state == _GzState.boundary) _state = _GzState.garbage;
    }
    switch (_state) {
      case _GzState.boundary || _GzState.garbage:
        return;
      case _GzState.header when _members > 0 && _headerBuf.isEmpty:
        return; // clean end exactly at a member boundary
      default:
        throw const FormatException('truncated gzip stream');
    }
  }

  void _startMemberBody() {
    _memberCrc = 0xFFFFFFFF;
    _memberSize = 0;
    _inflater = RawInflater(
      onOutput: (chunk) {
        if (verifyChecksums) {
          _memberCrc = crc32Update(_memberCrc, chunk, 0, chunk.length);
        }
        _memberSize += chunk.length;
        _totalOut += chunk.length;
        onOutput(chunk);
      },
    );
    _state = _GzState.body;
  }

  void _checkTrailer() {
    if (!verifyChecksums) return;
    final storedCrc =
        _trailer[0] |
        (_trailer[1] << 8) |
        (_trailer[2] << 16) |
        (_trailer[3] << 24);
    final storedSize =
        _trailer[4] |
        (_trailer[5] << 8) |
        (_trailer[6] << 16) |
        (_trailer[7] << 24);
    final actualCrc = (_memberCrc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
    if (storedCrc != actualCrc) {
      throw FormatException(
        'gzip CRC-32 mismatch (stored 0x${storedCrc.toRadixString(16)}, '
        'content 0x${actualCrc.toRadixString(16)})',
      );
    }
    if (storedSize != _memberSize % 0x100000000) {
      throw const FormatException('gzip ISIZE mismatch');
    }
  }
}

enum _GzState { header, body, trailer, boundary, garbage }

// ---------------------------------------------------------------------------
// Private CRC-32 (this package has zero dependencies by policy — §2 — so it
// cannot use koni_archive_core's Crc32; the table is 1 KiB).
// ---------------------------------------------------------------------------

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c;
  }
  return table;
}();

/// Updates a running CRC-32 (pass `0xFFFFFFFF` initially; finalize by
/// XOR-ing with `0xFFFFFFFF`). Exposed for framing internals and tests.
int crc32Update(int crc, Uint8List bytes, int start, int end) {
  var c = crc;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  }
  return c;
}

/// One-shot CRC-32 of `bytes[start..end)`.
int crc32OfSlice(Uint8List bytes, int start, int end) =>
    (crc32Update(0xFFFFFFFF, bytes, start, end) ^ 0xFFFFFFFF) & 0xFFFFFFFF;
