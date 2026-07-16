import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'rar20_decoder.dart';
import 'rar4_container.dart';
import 'rar4_decoder.dart';
import 'rar5_container.dart';
import 'rar5_decoder.dart';
import 'rar_crypto.dart';

/// Chunk size for slicing decoded output.
const int _readChunkSize = 64 * 1024;

/// Cap on a single decoded file / solid run (§7).
const int _maxFileSize = 1024 * 1024 * 1024;

/// One volume's slice of a multi-volume file's packed data.
final class _VolumeSegment {
  _VolumeSegment(this.source, this.offset, this.size);

  final ByteSource source;
  final int offset;
  final int size;
}

/// Reader for RAR5 and RAR4 archives (and CBR comics). Created via
/// `RarFormat.openReader`. RAR5 handles store + methods 1–5 (solid and
/// non-solid); RAR4 handles store + method-29 (solid and non-solid) with the
/// RarVM filters (the standard set natively, any other program on a generic
/// interpreter), and PPMd variant H (`-mct`, solid and non-solid); RAR 2.0/2.6
/// (unpack v20/v26) LZ also decodes. A mid-file PPMd→method-29 block switch, a
/// filter reached through PPMd, RAR 1.5 (v15), and the RAR 2.x audio block
/// surface as typed errors (see `doc/notes.md`).
final class RarReader extends ArchiveReader {
  RarReader._(
    this.format,
    this._source,
    this._options,
    this._headers, [
    this._segments,
  ]) : entries = List.unmodifiable([for (final h in _headers) _toEntry(h)]) {
    for (var i = 0; i < entries.length; i++) {
      _indexOf[entries[i]] = i;
    }
  }

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final ByteSource _source;
  final ArchiveReadOptions _options;
  final List<Rar5FileHeader> _headers;

  /// For a multi-volume set: per entry (parallel to [_headers]), the packed-
  /// data segments that make up that file, in order across volumes. Null for
  /// a single-volume archive, where data is read from [_source] directly.
  final List<List<_VolumeSegment>>? _segments;

  final Expando<int> _indexOf = Expando<int>();

  // Decoded solid run: the shared window decoder plus which file indices it
  // already covers. A jump backwards rebuilds from the run start.
  Rar5Decoder? _solidDecoder;
  int _solidNextIndex = 0;

  // RAR4 solid run: one decoder whose Huffman tables, repeated-offset cache,
  // and window persist across the run; plus each file's decoded slice.
  Rar4Decoder? _solidRar4Decoder;
  int _solidRar4NextIndex = 0;
  final Map<int, Uint8List> _solidRar4Outputs = {};

  bool _closed = false;

  // Derived keys, memoized by salt; the password is constant for a reader,
  // so the expensive KDF runs once per distinct salt.
  final Map<String, Rar5Keys> _rar5KeyCache = <String, Rar5Keys>{};
  final Map<String, Rar4Keys> _rar4KeyCache = <String, Rar4Keys>{};

  /// Parses the container (RAR5 or RAR4, per [isRar4]). Headers are
  /// plaintext unless whole-archive encryption is used; O(entry count), no
  /// content decode (§4).
  static Future<RarReader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options, {
    required bool isRar4,
  }) async {
    final toc =
        isRar4
            ? await parseRar4(source, 7, password: options.password)
            : await Rar5Toc.parse(source, 8, password: options.password);
    if (toc.headerEncrypted) {
      // Both `-hp` paths decrypt the headers in place when a password is
      // supplied (the crypt/main header keys every following block, and
      // `toc.files` is populated); a wrong password already threw
      // InvalidPasswordException. Without a password, the archive is locked.
      if (options.password == null) {
        throw EncryptedArchiveException(
          'the archive uses encrypted headers (rar -hp); supply '
          'ArchiveReadOptions.password',
          format: 'rar',
        );
      }
    }
    if (toc.isVolume) {
      return _parseMultiVolume(format, source, options, isRar4: isRar4);
    }
    return RarReader._(format, source, options, toc.files);
  }

  /// Assembles a multi-volume set: volume 1 is [firstSource], the rest come
  /// from `options.nextVolume`. A file whose data spans volumes appears in
  /// each with `splitBefore`/`splitAfter` set; its segments are merged into a
  /// single logical entry whose packed data is the segments concatenated.
  static Future<RarReader> _parseMultiVolume(
    ArchiveFormat format,
    ByteSource firstSource,
    ArchiveReadOptions options, {
    required bool isRar4,
  }) async {
    final resolver = options.nextVolume;
    if (resolver == null) {
      throw UnsupportedFeatureException(
        'multi-volume archive: supply ArchiveReadOptions.nextVolume to read '
        'the other volumes',
        format: 'rar',
      );
    }

    final headers = <Rar5FileHeader>[];
    final segments = <List<_VolumeSegment>>[];
    var expectingContinuation = false;

    void addVolume(ByteSource src, List<Rar5FileHeader> files) {
      for (final h in files) {
        if (h.splitBefore &&
            expectingContinuation &&
            headers.isNotEmpty &&
            headers.last.name == h.name) {
          // Continuation of the file split across the volume boundary.
          segments.last.add(_VolumeSegment(src, h.dataOffset, h.dataSize));
          // The final segment (splitAfter == false) carries the authoritative
          // full-file CRC — earlier occurrences store only their segment's CRC
          // — so adopt its header for the merged entry.
          if (!h.splitAfter) headers[headers.length - 1] = h;
        } else {
          headers.add(h);
          segments.add([_VolumeSegment(src, h.dataOffset, h.dataSize)]);
        }
        expectingContinuation = h.splitAfter;
      }
    }

    Future<Rar5Toc> parseVolume(ByteSource src) =>
        isRar4
            ? parseRar4(src, 7, password: options.password)
            : Rar5Toc.parse(src, 8, password: options.password);

    addVolume(firstSource, (await parseVolume(firstSource)).files);
    // Pull subsequent volumes until the resolver runs out; the cap only guards
    // against a resolver that never returns null.
    for (var volume = 2; volume < 1 << 20; volume++) {
      final next = await resolver(volume);
      if (next == null) break;
      addVolume(next, (await parseVolume(next)).files);
    }
    if (expectingContinuation) {
      throw UnexpectedEofException(
        'multi-volume archive is incomplete: a continuation volume is missing',
        format: 'rar',
      );
    }
    return RarReader._(format, firstSource, options, headers, segments);
  }

  static ArchiveEntry _toEntry(Rar5FileHeader h) {
    final normalized = normalizeEntryPath(h.name);
    final isSymlink = h.redirectTarget != null;
    return ArchiveEntry(
      path: normalized.path,
      pathEscapedRoot: normalized.escapedRoot,
      type:
          h.isDirectory
              ? ArchiveEntryType.directory
              : isSymlink
              ? ArchiveEntryType.symlink
              : ArchiveEntryType.file,
      uncompressedSize: h.unpackedSize,
      compressedSize: h.dataSize,
      compression:
          h.method == 0
              ? ArchiveCompression.stored
              : const ArchiveCompression.unknown(0x50), // RAR5 LZ ("rar5")
      modified: h.modified,
      posixMode: h.unixMode == null ? null : h.unixMode! & 0xFFF,
      crc32: h.crc32,
      isEncrypted: h.isEncrypted,
      linkTarget: h.redirectTarget,
    );
  }

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    final index = _indexOf[entry];
    if (index == null) {
      throw ArgumentError.value(entry, 'entry', 'not an entry of this archive');
    }
    final header = _headers[index];

    if (header.isEncrypted) {
      if (!_encryptionSupported(header)) {
        throw EncryptedArchiveException(
          'entry uses an unsupported encryption method',
          format: 'rar',
          entryPath: entry.path,
        );
      }
      if (_options.password == null) {
        throw EncryptedArchiveException(
          'entry is encrypted (-p); supply ArchiveReadOptions.password',
          format: 'rar',
          entryPath: entry.path,
        );
      }
    }
    if (header.version != 50 && header.version != 29) {
      throw UnsupportedFeatureException(
        'unsupported RAR compression version ${header.version}',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    if (header.isDirectory) {
      return const Stream<Uint8List>.empty();
    }
    // koni_rar decodes RAR4 *compressed* data of unpack version 20/26 (RAR
    // 2.0/2.6) and 29 (RAR 2.9/3.x). Version 15 (RAR 1.5) has no clean-room
    // reference and is rejected cleanly here — a typed error, not the confusing
    // corruption that misrouting it to the method-29 decoder would cause. Store
    // (method 0) is version-agnostic raw data and decodes at any version.
    if (header.version == 29 &&
        header.method != 0 &&
        header.unpackVersion != 29 &&
        header.unpackVersion != 20 &&
        header.unpackVersion != 26) {
      throw UnsupportedFeatureException(
        'RAR unpack version ${header.unpackVersion} is not supported '
        '(RAR 2.0/2.6/2.9/3.x and store decode)',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    if (header.unpackedSize > _maxFileSize) {
      throw CorruptArchiveException(
        'file claims implausible size ${header.unpackedSize}',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    return _streamEntry(index, header, entry);
  }

  Stream<Uint8List> _streamEntry(
    int index,
    Rar5FileHeader header,
    ArchiveEntry entry,
  ) async* {
    final Uint8List decoded;
    try {
      decoded = await _decodeToBytes(index, header, entry.path);
    } on FormatException catch (e) {
      // A decoder feature we deliberately defer (custom RarVM programs, the
      // mid-file PPMd→method-29 block switch) surfaces as an unsupported-
      // feature error, not corruption (§8/§9), so one such entry never
      // implies the archive is damaged.
      if (e.message.contains('not supported')) {
        throw UnsupportedFeatureException(
          e.message,
          format: 'rar',
          entryPath: entry.path,
        );
      }
      throw CorruptArchiveException(
        'bad compressed data: ${e.message}',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    if (_options.verifyChecksums && header.crc32 != null) {
      var actual = Crc32.compute(decoded);
      // Encrypted RAR5 files store a hash-key-tweaked CRC (so the checksum
      // reveals nothing about the plaintext); tweak the computed CRC the
      // same way before comparing. The tweak is gated by the record's "use
      // MAC" flag, which is set independently of the per-file password check
      // — `-hp` file records tweak the CRC without carrying a check value.
      final enc = header.encryption;
      if (enc != null && enc.useMac) {
        actual = _rar5Keys(enc, entry.path).tweakCrc(actual);
      }
      if (actual != header.crc32) {
        throw ChecksumMismatchException(
          'CRC-32 mismatch: archive records '
          '0x${header.crc32!.toRadixString(16)}, content is '
          '0x${actual.toRadixString(16)}',
          expected: header.crc32,
          actual: actual,
          format: 'rar',
          entryPath: entry.path,
        );
      }
    }
    var position = 0;
    while (position < decoded.length) {
      if (_closed) {
        throw ArchiveClosedException(
          'archive was closed while streaming entry',
          format: 'rar',
          entryPath: entry.path,
        );
      }
      final end =
          position + _readChunkSize < decoded.length
              ? position + _readChunkSize
              : decoded.length;
      yield Uint8List.sublistView(decoded, position, end);
      position = end;
    }
  }

  /// Returns the decoded content of file [index].
  Future<Uint8List> _decodeToBytes(
    int index,
    Rar5FileHeader header,
    String entryPath,
  ) async {
    final data = await _readData(index, header);
    if (header.method == 0) {
      // Stored: data is the content (solid store still just concatenates).
      // Encrypted data is padded to a 16-byte AES block, so allow a padded
      // tail and slice it off; plaintext store must match exactly.
      if (header.isEncrypted
          ? data.length < header.unpackedSize
          : data.length != header.unpackedSize) {
        throw const FormatException('stored RAR5 entry size mismatch');
      }
      return Uint8List.sublistView(data, 0, header.unpackedSize);
    }

    if (!header.solid) {
      // The LZ window must be a power of two (indices use `& mask`), and
      // big enough that the whole file fits without wrapping — so no byte
      // is overwritten before it is read out.
      final windowLen = _pow2Ceil(
        header.unpackedSize > header.windowSize
            ? header.unpackedSize
            : header.windowSize,
      );
      final output = Uint8List(windowLen);
      if (header.version != 29) {
        Rar5Decoder(output).decompressFile(data, header.unpackedSize);
      } else if (header.unpackVersion == 20 || header.unpackVersion == 26) {
        Rar20Decoder(output).decompressFile(data, header.unpackedSize);
      } else {
        Rar4Decoder(output).decompressFile(data, header.unpackedSize);
      }
      return Uint8List.sublistView(output, 0, header.unpackedSize);
    }

    // A *solid* RAR 2.0/2.6 run shares cross-file state the method-29 solid
    // path does not model; decoding a continuation there would misread v20 data
    // as method-29 and surface as corruption. Reject it cleanly instead (the
    // run's first file — a non-solid header — still decodes via the path above).
    // Full solid-v20 decode is deferred (doubly rare: vintage + solid).
    if (header.version == 29 &&
        (header.unpackVersion == 20 || header.unpackVersion == 26)) {
      throw UnsupportedFeatureException(
        'solid RAR 2.0/2.6 (unpack version ${header.unpackVersion}) '
        'continuations are not supported',
        format: 'rar',
        entryPath: entryPath,
      );
    }
    // Solid runs share cross-file state, so decode from the run start into a
    // shared window and keep every file's output (a later or repeat read is a
    // slice). RAR4 carries persistent Huffman tables + repeated-offset cache
    // (only the run's first file has a table block); RAR5 rebuilds per file.
    return header.version == 29
        ? _decodeSolidRar4(index, header, entryPath)
        : _decodeSolid(index, header, entryPath);
  }

  // Cache of decoded solid-file outputs by index (within the current run).
  final Map<int, Uint8List> _solidOutputs = {};

  Future<Uint8List> _decodeSolid(
    int index,
    Rar5FileHeader header,
    String entryPath,
  ) async {
    if (_solidOutputs.containsKey(index)) return _solidOutputs[index]!;

    // Find the start of this solid run (first file at/after the previous
    // non-solid boundary).
    var runStart = index;
    while (runStart > 0 && _headers[runStart].solid) {
      runStart--;
    }

    // (Re)build the run if our decoder is not positioned to continue.
    if (_solidDecoder == null || _solidNextIndex != runStart) {
      final windowSize = _runWindowSize(runStart);
      _solidDecoder = Rar5Decoder(Uint8List(windowSize));
      _solidNextIndex = runStart;
      _solidOutputs.clear();
    }
    final decoder = _solidDecoder!;
    final mask = decoder.output.length - 1;

    for (var i = _solidNextIndex; i <= index; i++) {
      final h = _headers[i];
      if (h.method == 0 || h.isDirectory) {
        // A stored or empty member inside a solid run: append raw. Encrypted
        // data carries AES padding — append only the declared bytes.
        final decrypted = await _readData(i, h);
        final raw =
            h.isEncrypted && decrypted.length > h.unpackedSize
                ? Uint8List.sublistView(decrypted, 0, h.unpackedSize)
                : decrypted;
        final start = decoder.writePtr;
        for (var j = 0; j < raw.length; j++) {
          decoder.output[(start + j) & mask] = raw[j];
        }
        decoder.writePtr += raw.length;
        _solidOutputs[i] = _extractWindow(decoder, start, raw.length, mask);
      } else {
        final start = decoder.writePtr;
        decoder.beginFileFilters();
        decoder.decompressFile(await _readData(i, h), h.unpackedSize);
        _solidOutputs[i] = _extractWindow(decoder, start, h.unpackedSize, mask);
      }
    }
    _solidNextIndex = index + 1;
    return _solidOutputs[index]!;
  }

  Uint8List _extractWindow(
    Rar5Decoder decoder,
    int start,
    int length,
    int mask,
  ) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = decoder.output[(start + i) & mask];
    }
    return out;
  }

  /// Decodes a solid RAR4 run. One [Rar4Decoder] carries the tables,
  /// repeated-offset cache, and window across the run; only the first
  /// compressed file parses a table (later files reuse it). The window is
  /// sized to hold the whole run without wrapping, so each file's output is a
  /// direct slice, kept for repeat/out-of-order reads.
  Future<Uint8List> _decodeSolidRar4(
    int index,
    Rar5FileHeader header,
    String entryPath,
  ) async {
    if (_solidRar4Outputs.containsKey(index)) return _solidRar4Outputs[index]!;

    // Run start: the first file at/after the previous non-solid boundary.
    var runStart = index;
    while (runStart > 0 && _headers[runStart].solid) {
      runStart--;
    }

    // A solid PPMd run shares one PPMd model across its members and cannot be
    // reframed per file the way method-29 is (each file is its own PPMd block
    // ending with an escape-code-2 marker whose symbols keep the shared model
    // in sync, and the block escape char carries across files). Decode the
    // whole run at once.
    if (await _isSolidPpmdRun(runStart)) {
      return _decodeSolidPpmdRun(index, runStart);
    }

    // (Re)build the run if the decoder is not positioned to continue.
    if (_solidRar4Decoder == null || _solidRar4NextIndex != runStart) {
      _solidRar4Decoder = Rar4Decoder(
        Uint8List(_solidRar4WindowSize(runStart)),
      );
      _solidRar4NextIndex = runStart;
      _solidRar4Outputs.clear();
    }
    final decoder = _solidRar4Decoder!;

    try {
      for (var i = _solidRar4NextIndex; i <= index; i++) {
        final h = _headers[i];
        final start = decoder.writePtr;
        if (h.method == 0 || h.isDirectory) {
          // Stored/empty member: append its bytes to the shared window so
          // later compressed members can still reference them.
          final decrypted = await _readData(i, h);
          final raw =
              h.isEncrypted && decrypted.length > h.unpackedSize
                  ? Uint8List.sublistView(decrypted, 0, h.unpackedSize)
                  : decrypted;
          decoder.output.setRange(start, start + raw.length, raw);
          decoder.writePtr += raw.length;
        } else {
          decoder.decompressFile(
            await _readData(i, h),
            h.unpackedSize,
            parseTable: !decoder.hasTables,
          );
        }
        _solidRar4Outputs[i] = Uint8List.fromList(
          Uint8List.sublistView(decoder.output, start, decoder.writePtr),
        );
        _solidRar4NextIndex = i + 1;
      }
    } catch (_) {
      // A mid-run failure leaves the shared decoder in an undefined state;
      // drop it so the next read rebuilds the run from scratch.
      _solidRar4Decoder = null;
      rethrow;
    }
    return _solidRar4Outputs[index]!;
  }

  /// Whether the solid run beginning at [runStart] is PPMd: peeks the first
  /// compressed member's first data byte, whose top bit is the block-type flag
  /// (data starts byte-aligned, and `_parseCodes` reads that bit first).
  Future<bool> _isSolidPpmdRun(int runStart) async {
    for (var i = runStart; i < _headers.length; i++) {
      if (i > runStart && !_headers[i].solid) break;
      final h = _headers[i];
      if (h.method == 0 || h.isDirectory) continue;
      final data = await _readData(i, h);
      return data.isNotEmpty && (data[0] & 0x80) != 0;
    }
    return false;
  }

  /// Decodes a solid RAR4 PPMd run whole and caches every member's output.
  /// One [Rar4Decoder] carries the shared PPMd model, escape symbol, and window
  /// across the run; each compressed member is decoded from its own block via
  /// [Rar4Decoder.decompressSolidPpmdFile] (run-to-marker, not to a byte count),
  /// and a stored/empty member's raw bytes are appended to the window between
  /// PPMd files so later matches can still reference them.
  Future<Uint8List> _decodeSolidPpmdRun(int index, int runStart) async {
    var runEnd = runStart;
    while (runEnd + 1 < _headers.length && _headers[runEnd + 1].solid) {
      runEnd++;
    }
    final decoder = Rar4Decoder(Uint8List(_solidRar4WindowSize(runStart)));
    // This run supersedes any in-flight method-29 solid decoder.
    _solidRar4Decoder = null;
    _solidRar4NextIndex = runEnd + 1;

    for (var i = runStart; i <= runEnd; i++) {
      final h = _headers[i];
      if (h.method == 0 || h.isDirectory) {
        final start = decoder.writePtr;
        final decrypted = await _readData(i, h);
        final raw =
            h.isEncrypted && decrypted.length > h.unpackedSize
                ? Uint8List.sublistView(decrypted, 0, h.unpackedSize)
                : decrypted;
        decoder.output.setRange(start, start + raw.length, raw);
        decoder.writePtr += raw.length;
        _solidRar4Outputs[i] = Uint8List.fromList(
          Uint8List.sublistView(decoder.output, start, decoder.writePtr),
        );
      } else {
        final slice = decoder.decompressSolidPpmdFile(
          await _readData(i, h),
          h.unpackedSize,
        );
        _solidRar4Outputs[i] = Uint8List.fromList(
          Uint8List.sublistView(decoder.output, slice.start, slice.end),
        );
      }
    }
    return _solidRar4Outputs[index]!;
  }

  /// Window big enough to hold the whole solid RAR4 run without wrapping.
  int _solidRar4WindowSize(int runStart) {
    var total = _headers[runStart].unpackedSize;
    for (var i = runStart + 1; i < _headers.length && _headers[i].solid; i++) {
      total += _headers[i].unpackedSize;
    }
    if (total > _maxFileSize) {
      throw CorruptArchiveException(
        'solid RAR4 run claims an implausible total size $total',
        format: 'rar',
      );
    }
    return _pow2Ceil(total < 0x20000 ? 0x20000 : total);
  }

  int _runWindowSize(int runStart) {
    var size = _headers[runStart].windowSize;
    for (var i = runStart + 1; i < _headers.length && _headers[i].solid; i++) {
      if (_headers[i].windowSize > size) size = _headers[i].windowSize;
    }
    return _pow2Ceil(size < 0x20000 ? 0x20000 : size);
  }

  static int _pow2Ceil(int value) {
    var pow = 0x20000;
    while (pow < value) {
      pow <<= 1;
    }
    return pow;
  }

  Future<Uint8List> _readData(int index, Rar5FileHeader header) async {
    final Uint8List raw;
    final segs = _segments?[index];
    if (segs != null) {
      // Multi-volume: concatenate this file's packed segments across volumes.
      var total = 0;
      for (final s in segs) {
        total += s.size;
      }
      if (total == 0) return Uint8List(0);
      raw = Uint8List(total);
      var pos = 0;
      for (final s in segs) {
        if (s.offset + s.size > s.source.length) {
          throw UnexpectedEofException(
            'multi-volume entry data extends past the end of a volume',
            format: 'rar',
            offset: s.offset,
          );
        }
        raw.setRange(pos, pos + s.size, await s.source.read(s.offset, s.size));
        pos += s.size;
      }
    } else {
      if (header.dataSize == 0) return Uint8List(0);
      if (header.dataOffset + header.dataSize > _source.length) {
        throw UnexpectedEofException(
          'entry data extends past the end of the archive',
          format: 'rar',
          offset: header.dataOffset,
        );
      }
      raw = await _source.read(header.dataOffset, header.dataSize);
    }
    if (!header.isEncrypted) return raw;
    return _decryptData(header, raw);
  }

  /// Whether we can decrypt [header]: RAR5 needs an AES-256 record, RAR4
  /// needs the header salt.
  bool _encryptionSupported(Rar5FileHeader header) => switch (header.version) {
    50 => header.encryption?.isAes256 ?? false,
    29 => header.rar4Salt != null,
    _ => false,
  };

  /// AES-CBC-decrypts an encrypted entry's packed bytes. The ciphertext is
  /// padded to a 16-byte boundary; the store/LZ layer above slices the
  /// plaintext to the declared unpacked size. Reachable without the
  /// openRead check via an encrypted member inside a solid run, so it
  /// re-validates and stays a typed error, never a null crash.
  Uint8List _decryptData(Rar5FileHeader header, Uint8List raw) {
    if (!_encryptionSupported(header)) {
      throw EncryptedArchiveException(
        'entry uses an unsupported encryption method',
        format: 'rar',
        entryPath: header.name,
      );
    }
    if (_options.password == null) {
      throw EncryptedArchiveException(
        'entry is encrypted (-p); supply ArchiveReadOptions.password',
        format: 'rar',
        entryPath: header.name,
      );
    }
    if (header.dataSize % 16 != 0) {
      throw CorruptArchiveException(
        'encrypted data length ${header.dataSize} is not a multiple of 16',
        format: 'rar',
        entryPath: header.name,
      );
    }
    return header.version == 29
        ? _decryptRar4(header, raw)
        : _decryptRar5(header, raw);
  }

  Uint8List _decryptRar5(Rar5FileHeader header, Uint8List raw) {
    final enc = header.encryption!;
    final keys = _rar5Keys(enc, header.name);
    if (enc.usePswCheck &&
        rar5PswCheckIntact(enc.pswCheck!, enc.pswCheckCsum!) &&
        !keys.passwordMatches(enc.pswCheck!)) {
      throw InvalidPasswordException(
        'password rejected by the RAR5 check value',
        format: 'rar',
        entryPath: header.name,
      );
    }
    final out = Uint8List.fromList(raw);
    keys.decrypt(out, enc.iv);
    return out;
  }

  Uint8List _decryptRar4(Rar5FileHeader header, Uint8List raw) {
    // RAR4 has no password-check value; a wrong password surfaces later as
    // a CRC-32 mismatch on the (plaintext) checksum.
    final keys = _rar4Keys(header.rar4Salt!);
    final out = Uint8List.fromList(raw);
    keys.decrypt(out);
    return out;
  }

  /// Derives (and memoizes) the RAR5 keys for an encryption record.
  Rar5Keys _rar5Keys(Rar5EncryptionInfo enc, String entryPath) {
    final cacheKey =
        '${enc.lg2Count}:${enc.salt.map((b) => b.toRadixString(16)).join()}';
    final cached = _rar5KeyCache[cacheKey];
    if (cached != null) return cached;
    final Rar5Keys keys;
    try {
      keys = Rar5Keys.derive(_options.password!, enc.salt, enc.lg2Count);
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'RAR5 key derivation failed: ${e.message}',
        format: 'rar',
        entryPath: entryPath,
      );
    }
    _rar5KeyCache[cacheKey] = keys;
    return keys;
  }

  /// Derives (and memoizes) the RAR4 keys for a header salt.
  Rar4Keys _rar4Keys(Uint8List salt) {
    final cacheKey = salt.map((b) => b.toRadixString(16)).join();
    return _rar4KeyCache[cacheKey] ??= Rar4Keys.derive(
      _options.password!,
      salt,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    _solidDecoder = null;
    _solidOutputs.clear();
    _solidRar4Decoder = null;
    _solidRar4Outputs.clear();
  }
}
