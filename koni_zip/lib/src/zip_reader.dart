import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

import 'structures.dart';
import 'zip_crypto.dart';

/// Chunk size for streaming entry content out of the source.
const int _readChunkSize = 64 * 1024;

/// Reader for ZIP archives (and CBZ comics). Created via
/// `ZipFormat.openReader`.
final class ZipReader extends ArchiveReader {
  ZipReader._(this.format, this._source, this._options, this._central)
    : entries = List.unmodifiable([for (final c in _central) c.entry]) {
    for (var i = 0; i < _central.length; i++) {
      _indexOf[_central[i].entry] = i;
    }
  }

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final ByteSource _source;
  final ArchiveReadOptions _options;
  final List<CentralEntry> _central;
  final Expando<int> _indexOf = Expando<int>();
  bool _closed = false;

  /// Locates the end-of-central-directory record (backward scan) and
  /// parses the central directory eagerly: O(entry count), no content
  /// reads. Local headers are validated lazily at [openRead].
  static Future<ZipReader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    final eocd = await Eocd.find(source);
    final maxCount = options.maxEntryCount;
    if (maxCount != null && eocd.totalEntries > maxCount) {
      // Reject before the directory loop allocates one record per entry.
      throw SizeLimitExceededException(
        'ZIP declares ${eocd.totalEntries} entries, over the maxEntryCount '
        'limit of $maxCount',
        limit: maxCount,
        format: 'zip',
      );
    }
    final central = await CentralEntry.parseDirectory(source, eocd, options);
    return ZipReader._(format, source, options, central);
  }

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    final index = _indexOf[entry];
    if (index == null) {
      throw ArgumentError.value(entry, 'entry', 'not an entry of this archive');
    }
    final central = _central[index];

    // Entry-scoped failures surface here, never at open: one exotic
    // entry must not brick the archive.
    if (entry.isEncrypted) {
      if (central.flags & 0x40 != 0) {
        throw EncryptedArchiveException(
          'entry uses ZIP strong encryption (SES), which is not supported '
          '($_encryptionScopeRef)',
          format: 'zip',
          entryPath: entry.path,
        );
      }
      if (central.methodId == 99 && central.aesExtra == null) {
        throw CorruptArchiveException(
          'AES entry is missing its 0x9901 extra field',
          format: 'zip',
          entryPath: entry.path,
        );
      }
      if (_options.password == null) {
        throw EncryptedArchiveException(
          central.methodId == 99
              ? 'entry is AES-encrypted; supply ArchiveReadOptions.password'
              : 'entry is encrypted (traditional PKWARE); '
                  'supply ArchiveReadOptions.password',
          format: 'zip',
          entryPath: entry.path,
        );
      }
    }

    final method =
        central.methodId == 99 ? central.effectiveMethodId : central.methodId;
    switch (method) {
      case 0:
        final contentLength = _contentLength(central);
        if (entry.uncompressedSize != contentLength) {
          throw CorruptArchiveException(
            'stored entry sizes disagree '
            '(content $contentLength, uncompressed ${entry.uncompressedSize})',
            format: 'zip',
            entryPath: entry.path,
          );
        }
        return _streamEntry(central, entry, compressed: false);
      case 8:
        return _streamEntry(central, entry, compressed: true);
      default:
        throw UnsupportedCompressionException(
          'compression method "${entry.compression.name}" '
          '(id $method) is not supported',
          methodName: entry.compression.name,
          methodId: method,
          format: 'zip',
          entryPath: entry.path,
        );
    }
  }

  static const String _encryptionScopeRef = 'doc/encryption-scope.md';

  /// Length of the decrypted content: the archive's stored size less any
  /// encryption header/salt/MAC overhead.
  int _contentLength(CentralEntry central) {
    if (!central.entry.isEncrypted) return central.compressedSize;
    if (central.methodId == 99) {
      final params = WinZipAesParams.fromExtra(central.aesExtra!);
      return central.compressedSize - (params?.overhead ?? 0);
    }
    return central.compressedSize - ZipCryptoCipher.headerSize;
  }

  Stream<Uint8List> _streamEntry(
    CentralEntry central,
    ArchiveEntry entry, {
    required bool compressed,
  }) async* {
    final dataOffset = await _dataOffset(central, entry);
    if (dataOffset + central.compressedSize > _source.length) {
      throw UnexpectedEofException(
        'entry data extends past the end of the archive',
        format: 'zip',
        offset: dataOffset,
        entryPath: entry.path,
      );
    }

    // AE-2 authenticates with HMAC and zeroes the CRC field, so CRC
    // verification is skipped there; every other scheme keeps a real CRC.
    var verifyCrc = _options.verifyChecksums && entry.crc32 != null;
    if (central.methodId == 99) {
      final params = WinZipAesParams.fromExtra(central.aesExtra!);
      if (params != null && params.vendorVersion == 2) verifyCrc = false;
    }

    final content = _decryptedContent(central, entry, dataOffset);
    if (compressed) {
      yield* _emitDeflated(entry, content, verifyCrc);
    } else {
      yield* _emitStored(entry, content, _contentLength(central), verifyCrc);
    }
  }

  /// Yields the decrypted, still-compression-layer content of the entry.
  /// For plaintext entries this is the raw stored bytes; for encrypted
  /// entries the cipher header/salt is stripped and the trailing MAC (AES)
  /// is verified once the ciphertext is exhausted.
  Stream<Uint8List> _decryptedContent(
    CentralEntry central,
    ArchiveEntry entry,
    int dataOffset,
  ) {
    if (!entry.isEncrypted) {
      return _rawRegion(entry, dataOffset, central.compressedSize);
    }
    if (central.methodId == 99) {
      return _aesContent(central, entry, dataOffset);
    }
    return _zipCryptoContent(central, entry, dataOffset);
  }

  /// Streams `length` raw bytes from [offset], honoring close mid-stream.
  Stream<Uint8List> _rawRegion(
    ArchiveEntry entry,
    int offset,
    int length,
  ) async* {
    var remaining = length;
    var pos = offset;
    while (remaining > 0) {
      _throwIfClosed(entry);
      final take = remaining < _readChunkSize ? remaining : _readChunkSize;
      yield await _source.read(pos, take);
      pos += take;
      remaining -= take;
    }
  }

  Stream<Uint8List> _zipCryptoContent(
    CentralEntry central,
    ArchiveEntry entry,
    int dataOffset,
  ) async* {
    if (central.compressedSize < ZipCryptoCipher.headerSize) {
      throw CorruptArchiveException(
        'encrypted entry is too small for its 12-byte cipher header',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    final cipher = ZipCryptoCipher(_passwordBytes());
    var headerRemaining = ZipCryptoCipher.headerSize;
    final header = Uint8List(ZipCryptoCipher.headerSize);
    await for (final raw in _rawRegion(
      entry,
      dataOffset,
      central.compressedSize,
    )) {
      final chunk = Uint8List.fromList(raw);
      cipher.process(chunk);
      var contentStart = 0;
      if (headerRemaining > 0) {
        final take =
            headerRemaining < chunk.length ? headerRemaining : chunk.length;
        header.setRange(
          ZipCryptoCipher.headerSize - headerRemaining,
          ZipCryptoCipher.headerSize - headerRemaining + take,
          chunk,
        );
        headerRemaining -= take;
        contentStart = take;
        if (headerRemaining == 0) {
          _checkZipCryptoHeader(central, entry, header);
        }
      }
      if (contentStart < chunk.length) {
        yield Uint8List.sublistView(chunk, contentStart);
      }
    }
  }

  void _checkZipCryptoHeader(
    CentralEntry central,
    ArchiveEntry entry,
    Uint8List header,
  ) {
    // The final header byte is checked against the CRC-32 high byte, or
    // (when the entry was written with a data descriptor, bit 3) the DOS
    // mod-time high byte, matching what the encoder had available.
    final expected =
        (central.flags & 0x08) != 0
            ? (central.dosTime >> 8) & 0xFF
            : ((entry.crc32 ?? 0) >> 24) & 0xFF;
    if (header[ZipCryptoCipher.headerSize - 1] != expected) {
      throw InvalidPasswordException(
        'password rejected by the traditional-cipher check byte',
        format: 'zip',
        entryPath: entry.path,
      );
    }
  }

  Stream<Uint8List> _aesContent(
    CentralEntry central,
    ArchiveEntry entry,
    int dataOffset,
  ) async* {
    final params = WinZipAesParams.fromExtra(central.aesExtra!);
    if (params == null) {
      throw CorruptArchiveException(
        'malformed AES (0x9901) extra field',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    if (central.compressedSize < params.overhead) {
      throw CorruptArchiveException(
        'AES entry is too small for its salt/verifier/MAC overhead',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    final head = await _source.read(dataOffset, params.saltLength + 2);
    final salt = Uint8List.sublistView(head, 0, params.saltLength);
    final verifier = Uint8List.sublistView(head, params.saltLength);
    final decryptor = WinZipAesDecryptor.derive(
      passwordBytes: _passwordBytes(),
      params: params,
      salt: Uint8List.fromList(salt),
      verifier: Uint8List.fromList(verifier),
      onBadPassword:
          () =>
              throw InvalidPasswordException(
                'password rejected by the AES verifier',
                format: 'zip',
                entryPath: entry.path,
              ),
    );

    final cipherStart = dataOffset + params.saltLength + 2;
    final cipherLength =
        central.compressedSize - params.overhead; // ciphertext only
    var remaining = cipherLength;
    var pos = cipherStart;
    while (remaining > 0) {
      _throwIfClosed(entry);
      final take = remaining < _readChunkSize ? remaining : _readChunkSize;
      final chunk = Uint8List.fromList(await _source.read(pos, take));
      decryptor.process(chunk);
      pos += take;
      remaining -= take;
      yield chunk;
    }

    final mac = await _source.read(pos, WinZipAesParams.macLength);
    if (!decryptor.verifyMac(Uint8List.fromList(mac))) {
      throw ChecksumMismatchException(
        'AES authentication code (HMAC-SHA1) mismatch',
        format: 'zip',
        entryPath: entry.path,
      );
    }
  }

  Uint8List _passwordBytes() =>
      Uint8List.fromList(utf8.encode(_options.password!));

  Stream<Uint8List> _emitStored(
    ArchiveEntry entry,
    Stream<Uint8List> content,
    int contentLength,
    bool verifyCrc,
  ) async* {
    final crc = verifyCrc ? Crc32() : null;
    var produced = 0;
    await for (final chunk in content) {
      _throwIfClosed(entry);
      produced += chunk.length;
      crc?.add(chunk);
      yield chunk;
    }
    if (produced != contentLength) {
      throw CorruptArchiveException(
        'stored entry produced $produced byte(s), expected $contentLength',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    _verifyCrc(crc, entry);
  }

  Stream<Uint8List> _emitDeflated(
    ArchiveEntry entry,
    Stream<Uint8List> content,
    bool verifyCrc,
  ) async* {
    final crc = verifyCrc ? Crc32() : null;
    final pending = <Uint8List>[];
    var producedTotal = 0;
    final inflater = RawInflater(
      onOutput: (chunk) {
        producedTotal += chunk.length;
        crc?.add(chunk);
        pending.add(chunk);
      },
    );

    try {
      await for (final chunk in content) {
        _throwIfClosed(entry);
        if (!inflater.isFinished) {
          inflater.addInput(chunk);
          // Decompression-bomb guard: decoded output beyond the
          // claimed uncompressed size is a typed error.
          if (producedTotal > entry.uncompressedSize) {
            throw SizeLimitExceededException(
              'decoded output exceeds the claimed uncompressed size '
              '(${entry.uncompressedSize} bytes)',
              limit: entry.uncompressedSize,
              format: 'zip',
              entryPath: entry.path,
            );
          }
          for (final decoded in pending) {
            yield decoded;
          }
          pending.clear();
        }
        // Fully drain `content` even once the inflate stream ends, so an
        // encrypted entry's trailing MAC is always reached and verified.
      }
      inflater.finish(); // throws FormatException when truncated
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad deflate stream: ${e.message}',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    for (final decoded in pending) {
      yield decoded;
    }
    if (producedTotal != entry.uncompressedSize) {
      throw CorruptArchiveException(
        'decoded $producedTotal byte(s), central directory claims '
        '${entry.uncompressedSize}',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    _verifyCrc(crc, entry);
  }

  void _verifyCrc(Crc32? crc, ArchiveEntry entry) {
    if (crc != null && crc.value != entry.crc32) {
      throw ChecksumMismatchException(
        'CRC-32 mismatch: archive records '
        '0x${entry.crc32!.toRadixString(16)}, content is '
        '0x${crc.value.toRadixString(16)}',
        expected: entry.crc32,
        actual: crc.value,
        format: 'zip',
        entryPath: entry.path,
      );
    }
  }

  void _throwIfClosed(ArchiveEntry entry) {
    if (_closed) {
      throw ArchiveClosedException(
        'archive was closed while streaming entry',
        format: 'zip',
        entryPath: entry.path,
      );
    }
  }

  /// Reads and validates the local file header; the content starts after
  /// its (independently sized) name and extra fields.
  Future<int> _dataOffset(CentralEntry central, ArchiveEntry entry) async {
    final header = await _source.read(central.localHeaderOffset, 30);
    final reader = ByteReader(header, baseOffset: central.localHeaderOffset);
    if (reader.readUint32le() != localHeaderSignature) {
      throw CorruptArchiveException(
        'central directory points at offset ${central.localHeaderOffset}, '
        'but there is no local file header there',
        format: 'zip',
        offset: central.localHeaderOffset,
        entryPath: entry.path,
      );
    }
    reader.position = 26;
    final nameLength = reader.readUint16le();
    final extraLength = reader.readUint16le();
    return central.localHeaderOffset + 30 + nameLength + extraLength;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
