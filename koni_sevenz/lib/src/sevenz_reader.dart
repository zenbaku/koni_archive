import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

import 'header.dart';
import 'sevenz_crypto.dart';

/// Chunk size for source reads and for slicing decoded folders out.
const int _readChunkSize = 64 * 1024;

/// Default cap for the decoded solid-block LRU cache: what makes CB7
/// page-flipping usable. The most recently decoded folder is always kept,
/// even when it alone exceeds the cap.
const int _folderCacheCap = 64 * 1024 * 1024;

/// Sanity cap for the (possibly compressed) header block.
const int _maxHeaderSize = 64 * 1024 * 1024;

/// Sanity cap for a single decoded folder: a forged unpack size must
/// not OOM the process. Real solid blocks (even whole-volume CB7s) sit
/// far below this; revisit if a legitimate archive ever hits it.
const int _maxFolderSize = 1024 * 1024 * 1024;

/// Reader for 7z archives (and CB7 comics). Created via
/// `SevenZFormat.openReader`.
final class SevenZReader extends ArchiveReader {
  SevenZReader._(
    this.format,
    this._source,
    this._options,
    this.entries,
    this._streams,
    this._entryStreams,
  ) {
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
  final SevenZStreamsInfo? _streams;

  /// Per entry: (folderIndex, offsetInFolder, size, crc32) or null for
  /// directories/empty files.
  final List<(int, int, int, int?)?> _entryStreams;

  final Expando<int> _indexOf = Expando<int>();
  bool _closed = false;

  // ---- solid-block cache ----
  final Map<int, Uint8List> _folderCache = <int, Uint8List>{};
  int _folderCacheBytes = 0;

  // Derived AES keys, memoized by (salt, cycle-power) so a multi-folder
  // encrypted archive pays for the expensive KDF once per salt.
  final Map<String, Uint8List> _keyCache = <String, Uint8List>{};

  /// Parses the signature header and the (often LZMA-compressed) archive
  /// header. Opening therefore decodes the header block, the documented
  /// caveat for 7z, but no entry content.
  static Future<SevenZReader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    if (source.length < 32) {
      throw UnexpectedEofException(
        'too short to be a 7z archive (${source.length} bytes)',
        format: '7z',
      );
    }
    final start = await source.read(0, 32);
    final reader = ByteReader(start);
    final magic = reader.readBytes(6);
    const expected = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];
    for (var i = 0; i < 6; i++) {
      if (magic[i] != expected[i]) {
        throw InvalidHeaderException('bad 7z signature', format: '7z');
      }
    }
    reader.skip(2); // version
    final startHeaderCrc = reader.readUint32le();
    final startHeader = reader.readBytes(20);
    if (options.verifyChecksums &&
        Crc32.compute(startHeader) != startHeaderCrc) {
      throw ChecksumMismatchException(
        'start header CRC mismatch',
        format: '7z',
        offset: 8,
      );
    }
    final sh = ByteReader(startHeader);
    final nextHeaderOffset = sh.readUint64le();
    final nextHeaderSize = sh.readUint64le();
    final nextHeaderCrc = sh.readUint32le();
    if (nextHeaderSize == 0) {
      // Empty archive: no header at all.
      return SevenZReader._(
        format,
        source,
        options,
        List.unmodifiable(<ArchiveEntry>[]),
        null,
        const [],
      );
    }
    if (nextHeaderSize > _maxHeaderSize ||
        32 + nextHeaderOffset + nextHeaderSize > source.length) {
      throw CorruptArchiveException(
        'archive header (offset $nextHeaderOffset, size $nextHeaderSize) '
        'does not fit in the file',
        format: '7z',
      );
    }
    var headerBytes = await source.read(32 + nextHeaderOffset, nextHeaderSize);
    if (options.verifyChecksums &&
        Crc32.compute(headerBytes) != nextHeaderCrc) {
      throw ChecksumMismatchException(
        'archive header CRC mismatch',
        format: '7z',
        offset: 32 + nextHeaderOffset,
      );
    }

    var header = ByteReader(headerBytes);
    var id = readSevenZipNumber(header);
    if (id == SevenZId.encodedHeader) {
      // The header itself is folder-compressed (usually LZMA).
      final streams = SevenZStreamsInfo.read(header);
      if (streams.folders.length != 1) {
        throw InvalidHeaderException(
          'encoded header must be a single folder',
          format: '7z',
        );
      }
      final folder = streams.folders.single;
      if (folder.unpackSize > _maxHeaderSize) {
        throw CorruptArchiveException(
          'encoded header claims implausible size ${folder.unpackSize}',
          format: '7z',
        );
      }
      try {
        headerBytes = await _decodeFolder(source, streams, 0, options);
      } on FormatException catch (e) {
        throw CorruptArchiveException(
          'bad compressed header: ${e.message}',
          format: '7z',
        );
      }
      if (options.verifyChecksums &&
          folder.crc != null &&
          Crc32.compute(headerBytes) != folder.crc) {
        throw ChecksumMismatchException(
          'decoded header CRC mismatch',
          format: '7z',
        );
      }
      header = ByteReader(headerBytes);
      id = readSevenZipNumber(header);
    }
    if (id != SevenZId.header) {
      throw InvalidHeaderException(
        'expected archive header, found property id $id',
        format: '7z',
      );
    }

    SevenZStreamsInfo? streams;
    SevenZFileInfo? files;
    id = readSevenZipNumber(header);
    if (id == SevenZId.archiveProperties) {
      // Skip property blocks.
      var type = readSevenZipNumber(header);
      while (type != SevenZId.end) {
        header.skip(readSevenZipNumber(header));
        type = readSevenZipNumber(header);
      }
      id = readSevenZipNumber(header);
    }
    if (id == SevenZId.additionalStreamsInfo) {
      throw UnsupportedFeatureException(
        'additional streams are not supported',
        format: '7z',
      );
    }
    if (id == SevenZId.mainStreamsInfo) {
      streams = SevenZStreamsInfo.read(header);
      id = readSevenZipNumber(header);
    }
    if (id == SevenZId.filesInfo) {
      files = SevenZFileInfo.read(header);
      id = readSevenZipNumber(header);
    }
    if (id != SevenZId.end) {
      throw InvalidHeaderException(
        'unexpected property id $id at end of header',
        format: '7z',
      );
    }

    return _build(format, source, options, streams, files);
  }

  static SevenZReader _build(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options,
    SevenZStreamsInfo? streams,
    SevenZFileInfo? files,
  ) {
    final entries = <ArchiveEntry>[];
    final entryStreams = <(int, int, int, int?)?>[];

    if (files == null) {
      // Streams without file metadata: expose substreams by index.
      if (streams != null) {
        var stream = 0;
        for (var f = 0; f < streams.folders.length; f++) {
          var offset = 0;
          for (var i = 0; i < streams.numUnpackStreams[f]; i++) {
            final size = streams.substreamSizes[stream];
            entries.add(
              ArchiveEntry(
                path: 'stream$stream',
                type: ArchiveEntryType.file,
                uncompressedSize: size,
                compression: _folderCompression(streams.folders[f]),
                isEncrypted: _folderIsEncrypted(streams.folders[f]),
                crc32: streams.substreamCrcs[stream],
              ),
            );
            entryStreams.add((f, offset, size, streams.substreamCrcs[stream]));
            offset += size;
            stream++;
          }
        }
      }
      return SevenZReader._(
        format,
        source,
        options,
        List.unmodifiable(entries),
        streams,
        entryStreams,
      );
    }

    // Map non-empty files to substreams in order.
    final folderOfStream = <int>[];
    final offsetInFolder = <int>[];
    if (streams != null) {
      var stream = 0;
      for (var f = 0; f < streams.folders.length; f++) {
        var offset = 0;
        for (var i = 0; i < streams.numUnpackStreams[f]; i++) {
          folderOfStream.add(f);
          offsetInFolder.add(offset);
          offset += streams.substreamSizes[stream];
          stream++;
        }
      }
    }

    var streamIndex = 0;
    var emptyIndex = 0;
    for (var i = 0; i < files.count; i++) {
      final name = i < files.names.length ? files.names[i] : 'file$i';
      final normalized = normalizeEntryPath(name);
      final attributes =
          i < files.attributes.length ? files.attributes[i] : null;
      final unixMode =
          attributes != null && (attributes & 0x8000) != 0
              ? (attributes >> 16) & 0xFFFF
              : null;
      final isEmptyStream =
          files.emptyStream.isNotEmpty && files.emptyStream[i];
      var isEmptyFile = false;
      if (isEmptyStream) {
        isEmptyFile =
            emptyIndex < files.emptyFile.length && files.emptyFile[emptyIndex];
        emptyIndex++;
      }
      final isDirectory =
          isEmptyStream && !isEmptyFile ||
          (attributes != null && (attributes & 0x10) != 0);
      final isSymlink = unixMode != null && (unixMode & 0xF000) == 0xA000;
      final modified = i < files.mTimes.length ? files.mTimes[i] : null;

      if (isEmptyStream) {
        entries.add(
          ArchiveEntry(
            path: normalized.path,
            pathEscapedRoot: normalized.escapedRoot,
            type:
                isDirectory
                    ? ArchiveEntryType.directory
                    : ArchiveEntryType.file,
            uncompressedSize: 0,
            modified: modified,
            posixMode: unixMode == null ? null : unixMode & 0xFFF,
          ),
        );
        entryStreams.add(null);
        continue;
      }
      if (streams == null || streamIndex >= streams.substreamSizes.length) {
        throw CorruptArchiveException(
          'file "$name" has content but the archive has no stream for it',
          format: '7z',
        );
      }
      final size = streams.substreamSizes[streamIndex];
      final crc = streams.substreamCrcs[streamIndex];
      final folderIndex = folderOfStream[streamIndex];
      entries.add(
        ArchiveEntry(
          path: normalized.path,
          pathEscapedRoot: normalized.escapedRoot,
          type: isSymlink ? ArchiveEntryType.symlink : ArchiveEntryType.file,
          uncompressedSize: size,
          compression: _folderCompression(streams.folders[folderIndex]),
          isEncrypted: _folderIsEncrypted(streams.folders[folderIndex]),
          modified: modified,
          posixMode: unixMode == null ? null : unixMode & 0xFFF,
          crc32: crc,
        ),
      );
      entryStreams.add((folderIndex, offsetInFolder[streamIndex], size, crc));
      streamIndex++;
    }

    return SevenZReader._(
      format,
      source,
      options,
      List.unmodifiable(entries),
      streams,
      entryStreams,
    );
  }

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    final index = _indexOf[entry];
    if (index == null) {
      throw ArgumentError.value(entry, 'entry', 'not an entry of this archive');
    }
    final location = _entryStreams[index];
    if (location == null) {
      return const Stream<Uint8List>.empty();
    }
    // Entry-scoped failures (unsupported codec, encryption) surface here,
    // never at open.
    final folder = _streams!.folders[location.$1];
    _checkFolderSupported(folder);
    if (_options.password == null && _folderIsEncrypted(folder)) {
      throw EncryptedArchiveException(
        'entry is AES-encrypted; supply ArchiveReadOptions.password',
        format: '7z',
        entryPath: entry.path,
      );
    }
    return _streamEntry(entry, location);
  }

  Stream<Uint8List> _streamEntry(
    ArchiveEntry entry,
    (int, int, int, int?) location,
  ) async* {
    final (folderIndex, offset, size, crc) = location;
    final folder = await _cachedFolder(folderIndex, entry.path);
    if (offset + size > folder.length) {
      throw CorruptArchiveException(
        'substream extends past its folder',
        format: '7z',
        entryPath: entry.path,
      );
    }
    if (_options.verifyChecksums && crc != null) {
      final actual = Crc32()..add(folder, offset, offset + size);
      if (actual.value != crc) {
        throw ChecksumMismatchException(
          'CRC-32 mismatch: archive records 0x${crc.toRadixString(16)}, '
          'content is 0x${actual.value.toRadixString(16)}',
          expected: crc,
          actual: actual.value,
          format: '7z',
          entryPath: entry.path,
        );
      }
    }
    var position = offset;
    final end = offset + size;
    while (position < end) {
      if (_closed) {
        throw ArchiveClosedException(
          'archive was closed while streaming entry',
          format: '7z',
          entryPath: entry.path,
        );
      }
      final chunkEnd =
          position + _readChunkSize < end ? position + _readChunkSize : end;
      yield Uint8List.sublistView(folder, position, chunkEnd);
      position = chunkEnd;
    }
  }

  /// Returns the decoded output of a folder, through the LRU cache.
  Future<Uint8List> _cachedFolder(int folderIndex, String entryPath) async {
    final cached = _folderCache.remove(folderIndex);
    if (cached != null) {
      _folderCache[folderIndex] = cached; // re-insert as most recent
      return cached;
    }
    final Uint8List decoded;
    try {
      decoded = await _decodeFolder(
        _source,
        _streams!,
        folderIndex,
        _options,
        keyCache: _keyCache,
      );
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad compressed data: ${e.message}',
        format: '7z',
        entryPath: entryPath,
      );
    }
    final folder = _streams.folders[folderIndex];
    if (_options.verifyChecksums &&
        folder.crc != null &&
        Crc32.compute(decoded) != folder.crc) {
      throw ChecksumMismatchException(
        'solid block CRC-32 mismatch',
        expected: folder.crc,
        format: '7z',
        entryPath: entryPath,
      );
    }
    _folderCache[folderIndex] = decoded;
    _folderCacheBytes += decoded.length;
    // Evict least-recently-used folders beyond the cap, always keeping the
    // one just decoded.
    while (_folderCacheBytes > _folderCacheCap && _folderCache.length > 1) {
      final oldest = _folderCache.keys.first;
      _folderCacheBytes -= _folderCache.remove(oldest)!.length;
    }
    return decoded;
  }

  /// Decodes one folder end-to-end: packed bytes through the coder chain.
  ///
  /// [keyCache] memoizes AES key derivations across a reader's folders
  /// (KDFs are expensive and share one salt per archive); it may be null
  /// for one-off decodes such as the encrypted header.
  static Future<Uint8List> _decodeFolder(
    ByteSource source,
    SevenZStreamsInfo streams,
    int folderIndex,
    ArchiveReadOptions options, {
    Map<String, Uint8List>? keyCache,
  }) async {
    final folder = streams.folders[folderIndex];
    _checkFolderSupported(folder);
    // Caller-set cap on a bulk decode (this runs for both the encoded header
    // and every content folder, so it covers 7z's two amplification points).
    final containerLimit = options.maxContainerDecodeSize;
    if (containerLimit != null && folder.unpackSize > containerLimit) {
      throw SizeLimitExceededException(
        'a 7z folder decodes to ${folder.unpackSize} byte(s), over the '
        'maxContainerDecodeSize limit of $containerLimit',
        limit: containerLimit,
        format: '7z',
      );
    }
    if (folder.unpackSize > _maxFolderSize) {
      throw CorruptArchiveException(
        'folder claims implausible unpacked size ${folder.unpackSize}',
        format: '7z',
      );
    }

    // Locate the folder's packed stream within the packed area.
    final packStart = streams.packStreamStarts()[folderIndex];
    var packOffset = 32 + streams.packPos;
    for (var i = 0; i < packStart; i++) {
      packOffset += streams.packSizes[i];
    }
    final packSize = streams.packSizes[packStart];
    if (packOffset + packSize > source.length) {
      throw UnexpectedEofException(
        'packed stream extends past the end of the archive',
        format: '7z',
        offset: packOffset,
      );
    }

    // Order coders from the packed stream to the folder output. Supported
    // folders are simple chains (single packed stream, 1-in/1-out coders),
    // so the chain is recovered by walking bind pairs.
    var chain = _coderChain(folder);

    // AES sits at the head of an encrypted chain (packed → AES → codec →
    // filters). Peel it: decrypt into a buffer, then run the already-proven
    // decompress/filter path over that plaintext with AES sliced off.
    var decodeSource = source;
    var decodeOffset = packOffset;
    var decodeSize = packSize;
    if (chain.first.idHex == _aesCoderId) {
      final decrypted = await _decryptAesCoder(
        source,
        packOffset,
        packSize,
        chain.first,
        _coderOutSize(folder, chain.first),
        options,
        keyCache,
      );
      if (chain.length == 1) return decrypted; // AES over raw store
      decodeSource = MemoryByteSource(decrypted);
      decodeOffset = 0;
      decodeSize = decrypted.length;
      chain = chain.sublist(1);
    }

    // First coder: decompressor over the (possibly decrypted) bytes.
    final buffer = await _decompress(
      decodeSource,
      decodeOffset,
      decodeSize,
      chain.first,
      _coderOutSize(folder, chain.first),
    );
    // Remaining coders: size-preserving filters, applied in place.
    for (final coder in chain.skip(1)) {
      _applyFilter(buffer, coder);
    }
    return buffer;
  }

  static const String _aesCoderId = '06f10701';

  static bool _folderIsEncrypted(SevenZFolder folder) =>
      folder.coders.any((c) => c.idHex == _aesCoderId);

  /// Reads and AES-256-CBC-decrypts a folder's packed stream, returning the
  /// coder's declared output (block padding sliced off).
  static Future<Uint8List> _decryptAesCoder(
    ByteSource source,
    int packOffset,
    int packSize,
    SevenZCoder coder,
    int outSize,
    ArchiveReadOptions options,
    Map<String, Uint8List>? keyCache,
  ) async {
    if (options.password == null) {
      throw EncryptedArchiveException(
        'the archive is AES-encrypted; supply ArchiveReadOptions.password',
        format: '7z',
      );
    }
    if (packSize % 16 != 0) {
      throw CorruptArchiveException(
        'AES packed stream length $packSize is not a multiple of 16',
        format: '7z',
        offset: packOffset,
      );
    }
    if (outSize > packSize) {
      throw CorruptArchiveException(
        'AES coder output ($outSize) exceeds its ciphertext ($packSize)',
        format: '7z',
      );
    }
    final SevenZAesProps props;
    try {
      props = SevenZAesProps.parse(coder.props);
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad AES coder properties: ${e.message}',
        format: '7z',
      );
    }
    final Uint8List key;
    try {
      final cacheKey = props.cacheKey();
      final cached = keyCache?[cacheKey];
      if (cached != null) {
        key = cached;
      } else {
        key = deriveSevenZAesKey(options.password!, props);
        keyCache?[cacheKey] = key;
      }
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'AES key derivation failed: ${e.message}',
        format: '7z',
      );
    }

    final buffer = Uint8List(packSize);
    var position = 0;
    while (position < packSize) {
      final take =
          packSize - position < _readChunkSize
              ? packSize - position
              : _readChunkSize;
      final chunk = await source.read(packOffset + position, take);
      buffer.setRange(position, position + take, chunk);
      position += take;
    }
    sevenZAesDecrypt(key, props.iv, buffer);
    return Uint8List.sublistView(buffer, 0, outSize);
  }

  /// Global out-stream index bookkeeping: out size of [coder].
  static int _coderOutSize(SevenZFolder folder, SevenZCoder coder) {
    var outIndex = 0;
    for (final c in folder.coders) {
      if (identical(c, coder)) return folder.unpackSizes[outIndex];
      outIndex += c.numOutStreams;
    }
    throw StateError('coder not in folder');
  }

  /// Orders the folder's coders from the packed stream to the final output.
  static List<SevenZCoder> _coderChain(SevenZFolder folder) {
    // In-stream index ranges per coder.
    final inStart = <int>[];
    var inIndex = 0;
    for (final coder in folder.coders) {
      inStart.add(inIndex);
      inIndex += coder.numInStreams;
    }
    int coderOfInStream(int stream) {
      for (var i = folder.coders.length - 1; i >= 0; i--) {
        if (stream >= inStart[i]) return i;
      }
      throw StateError('unreachable');
    }

    final chain = <SevenZCoder>[];
    var current = coderOfInStream(folder.packedIndices.single);
    for (;;) {
      chain.add(folder.coders[current]);
      // Which coder consumes this coder's output?
      var outIndex = 0;
      for (var i = 0; i < current; i++) {
        outIndex += folder.coders[i].numOutStreams;
      }
      (int, int)? pair;
      for (final p in folder.bindPairs) {
        if (p.$2 == outIndex) {
          pair = p;
          break;
        }
      }
      if (pair == null) return chain; // unbound: the folder output
      current = coderOfInStream(pair.$1);
      if (chain.length > folder.coders.length) {
        throw InvalidHeaderException(
          'cyclic coder graph in folder',
          format: '7z',
        );
      }
    }
  }

  static Future<Uint8List> _decompress(
    ByteSource source,
    int offset,
    int packSize,
    SevenZCoder coder,
    int outSize,
  ) async {
    final output = Uint8List(outSize);
    switch (coder.idHex) {
      case '00': // Copy
        if (packSize != outSize) {
          throw CorruptArchiveException(
            'copy coder sizes disagree',
            format: '7z',
          );
        }
        var position = 0;
        while (position < packSize) {
          final take =
              packSize - position < _readChunkSize
                  ? packSize - position
                  : _readChunkSize;
          final chunk = await source.read(offset + position, take);
          output.setRange(position, position + take, chunk);
          position += take;
        }
        return output;

      case '030101': // LZMA
        final decoder = LzmaDecoder.sevenZip(
          props: coder.props,
          output: output,
        );
        await _feed(source, offset, packSize, decoder.addInput);
        decoder.setInputComplete();
        if (!decoder.isChunkComplete) {
          throw const FormatException(
            'LZMA stream ended before the folder output was complete',
          );
        }
        return output;

      case '21': // LZMA2
        final decoder = Lzma2Decoder(
          output: output,
          dictSizeProp: coder.props.isEmpty ? null : coder.props[0],
        );
        await _feed(source, offset, packSize, decoder.addInput);
        if (!decoder.isFinished) {
          throw const FormatException(
            'LZMA2 stream ended before the folder output was complete',
          );
        }
        return output;

      case '040108': // Deflate
        var outPos = 0;
        final inflater = RawInflater(
          onOutput: (chunk) {
            if (outPos + chunk.length > output.length) {
              throw const FormatException(
                'deflate output exceeds the folder size',
              );
            }
            output.setRange(outPos, outPos + chunk.length, chunk);
            outPos += chunk.length;
          },
        );
        await _feed(source, offset, packSize, (chunk) {
          inflater.addInput(chunk);
        });
        inflater.finish();
        if (outPos != output.length) {
          throw const FormatException(
            'deflate stream ended before the folder output was complete',
          );
        }
        return output;

      default:
        throw _unsupportedCoder(coder);
    }
  }

  static Future<void> _feed(
    ByteSource source,
    int offset,
    int size,
    void Function(Uint8List chunk) sink,
  ) async {
    var position = 0;
    while (position < size) {
      final take =
          size - position < _readChunkSize ? size - position : _readChunkSize;
      sink(await source.read(offset + position, take));
      position += take;
    }
  }

  static void _applyFilter(Uint8List buffer, SevenZCoder coder) {
    switch (coder.idHex) {
      case '03': // Delta
        final distance = coder.props.isEmpty ? 1 : coder.props[0] + 1;
        deltaDecode(buffer, distance);
      case '03030103': // BCJ x86
        if (coder.props.isNotEmpty) {
          throw UnsupportedFeatureException(
            'BCJ start offsets are not supported',
            format: '7z',
          );
        }
        bcjX86Decode(buffer);
      default:
        throw _unsupportedCoder(coder);
    }
  }

  static void _checkFolderSupported(SevenZFolder folder) {
    if (folder.packedIndices.length != 1) {
      // Multi-input folders in practice mean BCJ2.
      throw UnsupportedCompressionException(
        'folders with multiple packed streams (BCJ2) are not supported',
        methodName: 'bcj2',
        format: '7z',
      );
    }
    for (final coder in folder.coders) {
      final supported = switch (coder.idHex) {
        '00' ||
        '030101' ||
        '21' ||
        '040108' ||
        '03' ||
        '03030103' ||
        _aesCoderId => true,
        _ => false,
      };
      if (!supported) {
        throw _unsupportedCoder(coder);
      }
      if (coder.numInStreams != 1 || coder.numOutStreams != 1) {
        throw UnsupportedCompressionException(
          'multi-stream coder ${coder.idHex} is not supported',
          methodName: _coderName(coder.idHex),
          format: '7z',
        );
      }
    }
  }

  static ArchiveException _unsupportedCoder(SevenZCoder coder) {
    // AES is decrypted when it heads the chain (see _decryptAesCoder); if it
    // reaches here it sat in a chain position we do not model.
    final name = _coderName(coder.idHex);
    return UnsupportedCompressionException(
      'codec "$name" (id ${coder.idHex}) is not supported',
      methodName: name,
      format: '7z',
    );
  }

  static String _coderName(String idHex) => switch (idHex) {
    '00' => 'copy',
    '03' => 'delta',
    '21' => 'lzma2',
    '030101' => 'lzma',
    '03030103' => 'bcj-x86',
    '0303011b' => 'bcj2',
    '030401' => 'ppmd',
    '040108' => 'deflate',
    '040202' => 'bzip2',
    '06f10701' => 'aes-256',
    _ => 'unknown',
  };

  static ArchiveCompression _folderCompression(SevenZFolder folder) {
    // Report the primary (de)compressor of the chain.
    for (final coder in folder.coders) {
      switch (coder.idHex) {
        case '030101':
          return ArchiveCompression.lzma;
        case '21':
          return ArchiveCompression.lzma2;
        case '040108':
          return ArchiveCompression.deflate;
        case '030401':
          return ArchiveCompression.ppmd;
        case '040202':
          return ArchiveCompression.bzip2;
      }
    }
    return ArchiveCompression.stored;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _folderCache.clear();
    _folderCacheBytes = 0;
  }
}
