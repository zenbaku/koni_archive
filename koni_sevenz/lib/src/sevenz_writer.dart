import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

import 'header.dart';

/// Writer for 7z archives (and CB7 comics). Created via
/// `SevenZWriteFormat.openWriter`.
///
/// ## Layout and the buffering caveat
///
/// A 7z file is `[32-byte signature header][packed streams][header]`. The
/// signature header sits at offset 0 but records the *offset, size, and CRC
/// of the trailing header* — which are only known once every packed stream
/// and the header itself have been produced. An append-only [ByteSink]
/// cannot seek back to patch offset 0, so this writer **buffers the packed
/// streams in memory** until [close], then emits signature header + packed
/// data + header in one pass. Input still streams through the compressor
/// (only the *compressed* output accumulates), so peak memory is bounded by
/// the compressed archive size — inherent to appending a 7z, whose reader is
/// itself a random-access format.
///
/// ## Coders (P2-4b)
///
/// LZMA2 (coder `21`, the format's own default), LZMA (`03 01 01`),
/// Deflate (`04 01 08`), and Copy (`00`); one folder per non-empty file
/// (non-solid). The header itself is LZMA-compressed (kEncodedHeader)
/// whenever that comes out smaller. LZMA coders are buffer-based: an
/// entry's *uncompressed* bytes are held in memory while it is encoded
/// (the buffer doubles as the match window), so peak memory adds the
/// largest entry's size to the packed-stream buffering described above —
/// Copy and Deflate entries still stream.
final class SevenZWriter extends ArchiveWriter {
  /// Creates a writer appending to [_sink].
  SevenZWriter(this.format, this._sink, this._options);

  @override
  final ArchiveWriteFormat format;

  final ByteSink _sink;
  final ArchiveWriteOptions _options;

  /// Compressed packed streams, folder-major, buffered until [close].
  final BytesBuilder _packed = BytesBuilder(copy: true);
  final List<_Folder> _folders = [];
  final List<_FileRecord> _files = [];
  bool _closed = false;

  // Internal coder selector (Copy/Deflate mirror the ZIP method ids for a
  // shared mental model; the 7z coder id bytes differ).
  static const int _copy = 0;
  static const int _deflate = 8;
  static const int _lzma = 14;
  static const int _lzma2 = 15;

  static const List<int> _copyId = [0x00];
  static const List<int> _deflateId = [0x04, 0x01, 0x08];
  static const List<int> _lzmaId = [0x03, 0x01, 0x01];
  static const List<int> _lzma2Id = [0x21];

  /// Dictionary bytes an LZMA coder is asked for: the entry size (the
  /// whole buffer is the window), floored at the format minimum and capped
  /// at 8 MiB so decoders never over-allocate for huge entries.
  static int _dictSizeFor(int length) {
    if (length < 1 << 12) return 1 << 12;
    if (length > 1 << 23) return 1 << 23;
    return length;
  }

  static const List<int> _signature = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];

  @override
  Future<ArchiveEntry> addStream(
    ArchiveEntrySpec spec,
    Stream<Uint8List> content, {
    required int size,
  }) async {
    _checkOpen();
    if (spec.type != ArchiveEntryType.file) {
      throw ArgumentError.value(
        spec.type,
        'spec.type',
        'addStream is for files; use addEntry for other types',
      );
    }
    final path = validateWritePath(spec.path);
    return _addFile(path, spec, content, size, isSymlink: false);
  }

  @override
  Future<ArchiveEntry> addEntry(ArchiveEntrySpec spec) async {
    _checkOpen();
    if (spec.type == ArchiveEntryType.file) {
      throw ArgumentError.value(
        spec.type,
        'spec.type',
        'a file needs content; use addStream/addBytes',
      );
    }
    final path = validateWritePath(spec.path);

    if (spec.type == ArchiveEntryType.symlink ||
        spec.type == ArchiveEntryType.hardlink) {
      // 7z has no link metadata: the target is stored as the entry content,
      // typed via the unix mode (S_IFLNK) in the Windows attribute word.
      final target = Uint8List.fromList(utf8.encode(spec.linkTarget ?? ''));
      return _addFile(
        path,
        spec,
        Stream<Uint8List>.value(target),
        target.length,
        isSymlink: true,
      );
    }

    // Directory: an empty-stream, non-empty-file entry.
    _files.add(
      _FileRecord(
        name: path,
        emptyStream: true,
        isEmptyFile: false,
        modified: spec.modified,
        attributes: _attributesFor(spec, isDir: true, isSymlink: false),
      ),
    );
    return ArchiveEntry(
      path: path,
      type: ArchiveEntryType.directory,
      uncompressedSize: 0,
      modified: spec.modified,
      posixMode: spec.posixMode,
    );
  }

  Future<ArchiveEntry> _addFile(
    String path,
    ArchiveEntrySpec spec,
    Stream<Uint8List> content,
    int size, {
    required bool isSymlink,
  }) async {
    final type = isSymlink ? ArchiveEntryType.symlink : ArchiveEntryType.file;

    if (size == 0) {
      // Zero content: an empty file (or empty-target link) — no folder, no
      // substream. Drain to honor the streaming contract and catch a
      // mis-declared size.
      await for (final chunk in content) {
        if (chunk.isNotEmpty) {
          throw SizeLimitExceededException(
            'entry "$path" streamed content but declared size 0',
            limit: 0,
            format: '7z',
            entryPath: path,
          );
        }
      }
      _files.add(
        _FileRecord(
          name: path,
          emptyStream: true,
          isEmptyFile: true,
          modified: spec.modified,
          attributes: _attributesFor(spec, isDir: false, isSymlink: isSymlink),
        ),
      );
      return ArchiveEntry(
        path: path,
        type: type,
        uncompressedSize: 0,
        compression: ArchiveCompression.stored,
        crc32: 0,
        modified: spec.modified,
        posixMode: spec.posixMode,
        linkTarget: isSymlink ? spec.linkTarget : null,
      );
    }

    final method = _methodOf(spec);
    final (packSize, crc, props) = await _compress(path, method, content, size);
    _folders.add(
      _Folder(
        coderId: _coderIdOf(method),
        props: props,
        packSize: packSize,
        unpackSize: size,
        crc: crc,
      ),
    );
    _files.add(
      _FileRecord(
        name: path,
        emptyStream: false,
        isEmptyFile: false,
        modified: spec.modified,
        attributes: _attributesFor(spec, isDir: false, isSymlink: isSymlink),
      ),
    );
    return ArchiveEntry(
      path: path,
      type: type,
      uncompressedSize: size,
      compressedSize: packSize,
      compression: _compressionOf(method),
      crc32: crc,
      modified: spec.modified,
      posixMode: spec.posixMode,
      linkTarget: isSymlink ? spec.linkTarget : null,
    );
  }

  /// Streams [content] into the packed buffer under [method], returning the
  /// compressed size, the CRC-32 of the *uncompressed* bytes (the folder
  /// CRC 7z records), and the coder's attribute blob when it has one.
  /// Validates the declared [size] against the stream. Copy and Deflate
  /// stream; the LZMA coders buffer the entry (see the class note).
  Future<(int, int, Uint8List?)> _compress(
    String path,
    int method,
    Stream<Uint8List> content,
    int size,
  ) async {
    final crc = Crc32();
    var uncompressed = 0;
    var packSize = 0;
    Uint8List? props;

    void checkOverrun(int chunkLength) {
      uncompressed += chunkLength;
      if (uncompressed > size) {
        throw SizeLimitExceededException(
          'entry "$path" streamed more than the declared size $size',
          limit: size,
          format: '7z',
          entryPath: path,
        );
      }
    }

    if (method == _copy) {
      await for (final chunk in content) {
        checkOverrun(chunk.length);
        crc.add(chunk);
        _packed.add(chunk);
        packSize += chunk.length;
      }
    } else if (method == _deflate) {
      final deflater = RawDeflater(
        onOutput: (out) {
          _packed.add(out);
          packSize += out.length;
        },
      );
      await for (final chunk in content) {
        checkOverrun(chunk.length);
        crc.add(chunk);
        deflater.add(chunk);
      }
      deflater.finish();
    } else {
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in content) {
        checkOverrun(chunk.length);
        crc.add(chunk);
        buffer.add(chunk);
      }
      final data = buffer.takeBytes();
      final dictSize = _dictSizeFor(data.length);
      Uint8List out;
      if (method == _lzma) {
        final encoder = LzmaEncoder(dictSize: dictSize);
        out = encoder.encode(data);
        props = encoder.sevenZipProps();
      } else {
        final encoder = Lzma2Encoder(dictSize: dictSize);
        out = encoder.encode(data);
        props = Uint8List.fromList([encoder.dictSizeProp]);
      }
      _packed.add(out);
      packSize = out.length;
    }

    if (uncompressed != size) {
      throw CorruptArchiveException(
        'entry "$path" streamed $uncompressed bytes, declared $size',
        format: '7z',
        entryPath: path,
      );
    }
    return (packSize, crc.value, props);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    final packed = _packed.takeBytes();
    final header = _buildHeader();

    // kEncodedHeader: LZMA-compress the header itself; keep whichever form
    // is smaller overall. The header's packed stream joins the packed area
    // right after the folders' streams (packPos = main packed length).
    var trailing = header;
    Uint8List? headerPacked;
    final encoder = LzmaEncoder(dictSize: _dictSizeFor(header.length));
    final compressed = encoder.encode(header);
    final wrapped = _buildEncodedHeader(
      packPos: packed.length,
      packSize: compressed.length,
      unpackSize: header.length,
      props: encoder.sevenZipProps(),
      crc: Crc32.compute(header),
    );
    if (compressed.length + wrapped.length < header.length) {
      headerPacked = compressed;
      trailing = wrapped;
    }

    final packedTotal = packed.length + (headerPacked?.length ?? 0);

    // Start header (20 bytes): offset + size + CRC of the trailing header.
    final startHeader =
        _SevenZBuffer()
          ..u64(packedTotal) // NextHeaderOffset (from byte 32)
          ..u64(trailing.length) // NextHeaderSize
          ..u32(Crc32.compute(trailing)); // NextHeaderCRC
    final startBytes = startHeader.take();

    final signature =
        _SevenZBuffer()
          ..writeBytes(_signature)
          ..writeBytes(const [0x00, 0x04]) // format version 0.4
          ..u32(Crc32.compute(startBytes)) // StartHeaderCRC
          ..writeBytes(startBytes);

    await _sink.add(signature.take());
    if (packed.isNotEmpty) await _sink.add(packed);
    if (headerPacked != null) await _sink.add(headerPacked);
    await _sink.add(trailing);
  }

  /// The kEncodedHeader structure: a StreamsInfo describing the single
  /// LZMA folder that decompresses to the real header (the exact shape the
  /// reader's encoded-header branch parses).
  Uint8List _buildEncodedHeader({
    required int packPos,
    required int packSize,
    required int unpackSize,
    required Uint8List props,
    required int crc,
  }) {
    final h =
        _SevenZBuffer()
          ..number(SevenZId.encodedHeader)
          // PackInfo
          ..number(SevenZId.packInfo)
          ..number(packPos)
          ..number(1)
          ..number(SevenZId.size)
          ..number(packSize)
          ..number(SevenZId.end)
          // UnpackInfo: one LZMA folder with its attribute blob.
          ..number(SevenZId.unpackInfo)
          ..number(SevenZId.folder)
          ..number(1)
          ..writeByte(0) // folders are inline
          ..number(1) // numCoders
          ..writeByte(_lzmaId.length | 0x20) // id size + attributes bit
          ..writeBytes(_lzmaId)
          ..number(props.length)
          ..writeBytes(props)
          ..number(SevenZId.codersUnpackSize)
          ..number(unpackSize)
          ..number(SevenZId.crc)
          ..writeByte(1) // all CRCs defined
          ..u32(crc)
          ..number(SevenZId.end) // end UnpackInfo
          ..number(SevenZId.end); // end StreamsInfo
    return h.take();
  }

  // ---- header serialization (inverse of header.dart's parsers) ----

  Uint8List _buildHeader() {
    final h = _SevenZBuffer()..number(SevenZId.header);
    if (_folders.isNotEmpty) _writeStreamsInfo(h);
    if (_files.isNotEmpty) _writeFilesInfo(h);
    h.number(SevenZId.end);
    return h.take();
  }

  void _writeStreamsInfo(_SevenZBuffer h) {
    h
      ..number(SevenZId.mainStreamsInfo)
      // PackInfo
      ..number(SevenZId.packInfo)
      ..number(0) // packPos: packed area starts right after the sig header
      ..number(_folders.length)
      ..number(SevenZId.size);
    for (final f in _folders) {
      h.number(f.packSize);
    }
    h
      ..number(SevenZId.end)
      // UnpackInfo
      ..number(SevenZId.unpackInfo)
      ..number(SevenZId.folder)
      ..number(_folders.length)
      ..writeByte(0); // folders are inline, not external
    for (final f in _folders) {
      _writeFolder(h, f);
    }
    h.number(SevenZId.codersUnpackSize);
    for (final f in _folders) {
      h.number(f.unpackSize);
    }
    // Folder CRCs (all defined). With one substream per folder this also
    // serves as the substream CRC, so SubStreamsInfo can be omitted.
    h
      ..number(SevenZId.crc)
      ..writeByte(1); // all CRCs defined
    for (final f in _folders) {
      h.u32(f.crc);
    }
    h
      ..number(SevenZId.end) // end UnpackInfo
      ..number(SevenZId.end); // end StreamsInfo (no SubStreamsInfo)
  }

  void _writeFolder(_SevenZBuffer h, _Folder folder) {
    // One coder, 1-in/1-out: flags = id-size in the low nibble, plus the
    // attributes bit when the coder carries properties (LZMA/LZMA2). No
    // bind pairs, and the single packed stream index is implicit.
    final props = folder.props;
    h
      ..number(1) // numCoders
      ..writeByte(folder.coderId.length | (props == null ? 0 : 0x20))
      ..writeBytes(folder.coderId);
    if (props != null) {
      h
        ..number(props.length)
        ..writeBytes(props);
    }
  }

  void _writeFilesInfo(_SevenZBuffer h) {
    h
      ..number(SevenZId.filesInfo)
      ..number(_files.length);

    final anyEmptyStream = _files.any((f) => f.emptyStream);
    if (anyEmptyStream) {
      final v =
          _SevenZBuffer()..bitVector([for (final f in _files) f.emptyStream]);
      _property(h, SevenZId.emptyStream, v);

      final emptyStreams = _files.where((f) => f.emptyStream).toList();
      if (emptyStreams.any((f) => f.isEmptyFile)) {
        final ef =
            _SevenZBuffer()
              ..bitVector([for (final f in emptyStreams) f.isEmptyFile]);
        _property(h, SevenZId.emptyFile, ef);
      }
    }

    // Names: external flag then UTF-16LE, each null-terminated.
    final names = _SevenZBuffer()..writeByte(0);
    for (final f in _files) {
      for (final unit in f.name.codeUnits) {
        names.u16(unit);
      }
      names.u16(0);
    }
    _property(h, SevenZId.name, names);

    if (_files.any((f) => f.modified != null)) {
      final t =
          _SevenZBuffer()
            ..boolsAllOrBits([for (final f in _files) f.modified != null])
            ..writeByte(0); // times are inline
      for (final f in _files) {
        if (f.modified != null) t.fileTime(f.modified!);
      }
      _property(h, SevenZId.mTime, t);
    }

    if (_files.any((f) => f.attributes != null)) {
      final a =
          _SevenZBuffer()
            ..boolsAllOrBits([for (final f in _files) f.attributes != null])
            ..writeByte(0); // attributes are inline
      for (final f in _files) {
        if (f.attributes != null) a.u32(f.attributes!);
      }
      _property(h, SevenZId.winAttributes, a);
    }

    h.number(SevenZId.end);
  }

  /// Emits a size-prefixed FilesInfo property: id, byte length, payload.
  void _property(_SevenZBuffer h, int id, _SevenZBuffer payload) {
    h
      ..number(id)
      ..number(payload.length)
      ..append(payload);
  }

  int _methodOf(ArchiveEntrySpec spec) {
    final requested = spec.compression ?? _options.compression;
    if (requested == null || requested == ArchiveCompression.lzma2) {
      return _lzma2; // the format's own default
    }
    if (requested == ArchiveCompression.lzma) return _lzma;
    if (requested == ArchiveCompression.deflate) return _deflate;
    if (requested == ArchiveCompression.stored) return _copy;
    throw UnsupportedCompressionException(
      '7z writing supports stored (copy), deflate, lzma, and lzma2; '
      '"${requested.name}" is not available',
      methodName: requested.name,
      format: '7z',
      entryPath: spec.path,
    );
  }

  static List<int> _coderIdOf(int method) => switch (method) {
    _copy => _copyId,
    _deflate => _deflateId,
    _lzma => _lzmaId,
    _ => _lzma2Id,
  };

  static ArchiveCompression _compressionOf(int method) => switch (method) {
    _copy => ArchiveCompression.stored,
    _deflate => ArchiveCompression.deflate,
    _lzma => ArchiveCompression.lzma,
    _ => ArchiveCompression.lzma2,
  };

  /// The Windows attribute word: the DOS directory bit plus, when a unix
  /// mode is meaningful, the `FILE_ATTRIBUTE_UNIX_EXTENSION` (0x8000) flag
  /// with the full mode in the high 16 bits — exactly what the reader
  /// decodes back into `posixMode`, symlink typing, and directory typing.
  int? _attributesFor(
    ArchiveEntrySpec spec, {
    required bool isDir,
    required bool isSymlink,
  }) {
    if (isSymlink) {
      final mode = 0xA000 | ((spec.posixMode ?? 0x1FF) & 0xFFF); // S_IFLNK
      return 0x8000 + mode * 0x10000;
    }
    if (isDir) {
      if (spec.posixMode == null) return 0x10; // DOS directory bit only
      final mode = 0x4000 | (spec.posixMode! & 0xFFF); // S_IFDIR
      return 0x8000 + mode * 0x10000 + 0x10;
    }
    if (spec.posixMode == null) return null; // plain file, no mode recorded
    final mode = 0x8000 | (spec.posixMode! & 0xFFF); // S_IFREG
    return 0x8000 + mode * 0x10000;
  }

  void _checkOpen() {
    if (_closed) {
      throw ArchiveClosedException('writer is closed', format: '7z');
    }
  }
}

/// A written folder: one coder over one file's content.
final class _Folder {
  _Folder({
    required this.coderId,
    required this.props,
    required this.packSize,
    required this.unpackSize,
    required this.crc,
  });

  final List<int> coderId;
  final Uint8List? props;
  final int packSize;
  final int unpackSize;
  final int crc;
}

/// A written file/dir/link entry's metadata.
final class _FileRecord {
  _FileRecord({
    required this.name,
    required this.emptyStream,
    required this.isEmptyFile,
    required this.modified,
    required this.attributes,
  });

  final String name;
  final bool emptyStream;
  final bool isEmptyFile;
  final DateTime? modified;
  final int? attributes;
}

/// Byte assembler for 7z structures. All multi-byte writes use `%`/`~/`
/// arithmetic (never bitwise on values that can exceed 2^31), so the output
/// is identical on the VM, dart2js, and dart2wasm.
final class _SevenZBuffer {
  final BytesBuilder _b = BytesBuilder(copy: true);

  int get length => _b.length;

  void writeByte(int b) => _b.addByte(b);
  void writeBytes(List<int> data) => _b.add(data);
  void append(_SevenZBuffer other) => _b.add(other.take());
  Uint8List take() => _b.takeBytes();

  void u16(int v) {
    writeByte(v % 256);
    writeByte((v ~/ 256) % 256);
  }

  void u32(int v) {
    var x = v;
    for (var i = 0; i < 4; i++) {
      writeByte(x % 256);
      x = x ~/ 256;
    }
  }

  void u64(int v) {
    var x = v;
    for (var i = 0; i < 8; i++) {
      writeByte(x % 256);
      x = x ~/ 256;
    }
  }

  /// 7z's variable-length number (inverse of `readSevenZipNumber`): a prefix
  /// of 1-bits in the first byte counts the little-endian extra bytes; the
  /// remaining low bits of the first byte hold the high part.
  void number(int value) {
    var firstByte = 0;
    var mask = 0x80;
    final extra = <int>[];
    var v = value;
    for (var i = 0; i < 8; i++) {
      if (v < (1 << (7 - i))) {
        firstByte |= v; // high part fits in the remaining (7 - i) bits
        writeByte(firstByte);
        for (final b in extra) {
          writeByte(b);
        }
        return;
      }
      firstByte |= mask;
      mask >>= 1;
      extra.add(v % 256);
      v = v ~/ 256;
    }
    writeByte(0xFF); // 8 extra bytes (unreachable for values < 2^53)
    for (final b in extra) {
      writeByte(b);
    }
  }

  /// A bit vector, MSB-first within each byte (inverse of `readBitVector`).
  void bitVector(List<bool> bits) {
    var b = 0;
    var mask = 0x80;
    for (final bit in bits) {
      if (bit) b |= mask;
      mask >>= 1;
      if (mask == 0) {
        writeByte(b);
        b = 0;
        mask = 0x80;
      }
    }
    if (mask != 0x80) writeByte(b);
  }

  /// The "all defined, or a bit vector" encoding: a single non-zero byte
  /// when every bit is set, else a zero byte followed by the vector.
  void boolsAllOrBits(List<bool> bits) {
    if (bits.every((b) => b)) {
      writeByte(1);
    } else {
      writeByte(0);
      bitVector(bits);
    }
  }

  /// A Windows FILETIME (100 ns since 1601), the inverse of the reader's
  /// `_fileTime`. Split into 32-bit halves with arithmetic that stays below
  /// 2^53 so it is exact on every platform.
  void fileTime(DateTime utc) {
    final ms = utc.millisecondsSinceEpoch + 11644473600000;
    final msLo = ms % 0x100000000;
    final msHi = ms ~/ 0x100000000;
    final lowProduct = msLo * 10000;
    u32(lowProduct % 0x100000000);
    final carry = lowProduct ~/ 0x100000000;
    // hi holds the remaining 100 ns units; well under 2^32 for real dates.
    u32(msHi * 10000 + carry);
  }
}
