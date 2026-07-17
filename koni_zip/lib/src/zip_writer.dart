import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

import 'zip_crypto.dart';

/// Writer for ZIP archives (and CBZ comics). Created via
/// `ZipWriteFormat.openWriter`.
///
/// Streams each entry with a data descriptor (general-purpose flag bit 3),
/// so the CRC and compressed size need not be known before the data; the
/// central directory (written at [close]) carries the authoritative values.
/// Stored and deflate (default) methods; ZIP64 structures are emitted when
/// a size, offset, or the entry count exceeds the 32-bit / 16-bit limits.
///
/// When [ArchiveWriteOptions.password] is set, file and symlink entries are
/// encrypted with **WinZip AES-256 (AE-2)**: method 99 with the real
/// method in the 0x9901 extra, a per-entry salt, PBKDF2-HMAC-SHA1 keys, and
/// an HMAC-SHA1 authentication tag (so the CRC field is zeroed, as AE-2
/// requires). Directory entries carry no data and stay unencrypted.
final class ZipWriter extends ArchiveWriter {
  /// Creates a writer appending to [_sink]. [randomBytes] overrides the
  /// salt source (a cryptographic RNG by default); tests inject a
  /// deterministic generator to pin the ciphertext.
  ZipWriter(
    this.format,
    this._sink,
    this._options, {
    Uint8List Function(int length)? randomBytes,
  }) : _randomBytes = randomBytes ?? _secureRandomBytes;

  @override
  final ArchiveWriteFormat format;

  final ByteSink _sink;
  final ArchiveWriteOptions _options;
  final Uint8List Function(int length) _randomBytes;
  final List<_CentralRecord> _central = [];
  bool _closed = false;

  /// AES strength for encrypted entries: 3 = AES-256 (salt 16, key 32).
  static const int _aesStrength = 3;

  static final Random _secureRng = Random.secure();

  static Uint8List _secureRandomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _secureRng.nextInt(256);
    }
    return out;
  }

  static const int _localSig = 0x04034B50;
  static const int _centralSig = 0x02014B50;
  static const int _descriptorSig = 0x08074B50;
  static const int _eocdSig = 0x06054B50;
  static const int _eocd64Sig = 0x06064B50;
  static const int _eocd64LocatorSig = 0x07064B50;
  static const int _u32Max = 0xFFFFFFFF;

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
    final path =
        _options.allowUnsafePaths ? spec.path : validateWritePath(spec.path);
    final method = _methodOf(spec);
    return _writeFile(path, spec, method, content, size, isSymlink: false);
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
    final path =
        _options.allowUnsafePaths ? spec.path : validateWritePath(spec.path);

    if (spec.type == ArchiveEntryType.symlink ||
        spec.type == ArchiveEntryType.hardlink) {
      // ZIP stores a link's target as the entry content, flagged by the
      // unix mode (S_IFLNK) in the external attributes.
      final target = Uint8List.fromList((spec.linkTarget ?? '').codeUnits);
      return _writeFile(
        path,
        spec,
        0, // links are stored
        Stream<Uint8List>.value(target),
        target.length,
        isSymlink: spec.type == ArchiveEntryType.symlink,
      );
    }

    // Directory: a zero-length stored entry whose name ends in '/'.
    final dirPath = '$path/';
    final entry = await _writeFile(
      dirPath,
      spec,
      0,
      const Stream<Uint8List>.empty(),
      0,
      isSymlink: false,
      isDirectory: true,
    );
    return ArchiveEntry(
      path: path,
      type: ArchiveEntryType.directory,
      uncompressedSize: 0,
      modified: entry.modified,
      posixMode: spec.posixMode,
    );
  }

  Future<ArchiveEntry> _writeFile(
    String path,
    ArchiveEntrySpec spec,
    int method,
    Stream<Uint8List> content,
    int size, {
    required bool isSymlink,
    bool isDirectory = false,
  }) async {
    // Encrypt entries that carry data (files, symlinks); directories don't.
    final encrypt = _options.password != null && !isDirectory;
    WinZipAesParams? aesParams;
    WinZipAesEncryptor? enc;
    if (encrypt) {
      aesParams = WinZipAesParams.ae2(strength: _aesStrength, method: method);
      enc = WinZipAesEncryptor.derive(
        passwordBytes: _passwordBytes(),
        params: aesParams,
        salt: _randomBytes(aesParams.saltLength),
      );
    }
    final overhead = aesParams?.overhead ?? 0;
    final aesExtra = aesParams == null ? null : _aesExtraField(aesParams);

    final nameBytes = Uint8List.fromList(_utf8(path));
    final localOffset = _sink.length;
    // ZIP64 is needed when the uncompressed size or this entry's offset
    // exceeds 32 bits. Compressed size can only grow slightly beyond a 4 GiB
    // uncompressed size (deflate) plus the AES envelope, so size + overhead
    // is a safe proxy for deciding it up front.
    final zip64 = size + overhead > _u32Max || localOffset > _u32Max;
    final (dosTime, dosDate) = _dosDateTime(spec.modified);
    // Encrypted entries advertise method 99; the real method rides in the
    // 0x9901 extra. AES needs extract version 51.
    final headerMethod = encrypt ? 99 : method;
    final versionNeeded = encrypt ? 51 : (zip64 ? 45 : 20);
    final zip64Extra =
        zip64
            ? (_ByteWriter()
                  ..u16(0x0001)
                  ..u16(16)
                  ..u64(
                    0,
                  ) // uncompressed size placeholder (descriptor is truth)
                  ..u64(0)) // compressed size placeholder
                .take()
            : null;
    final extraLen = (aesExtra?.length ?? 0) + (zip64Extra?.length ?? 0);

    // Local file header (sizes deferred to the data descriptor via bit 3).
    final local =
        _ByteWriter()
          ..u32(_localSig)
          ..u16(versionNeeded)
          // flags: bit 3 (data descriptor) + bit 11 (UTF-8), + bit 0 when
          // encrypted.
          ..u16(encrypt ? 0x0809 : 0x0808)
          ..u16(headerMethod)
          ..u16(dosTime)
          ..u16(dosDate)
          ..u32(0) // crc: in the descriptor (and zeroed for AE-2)
          ..u32(zip64 ? _u32Max : 0) // compressed size
          ..u32(zip64 ? _u32Max : 0) // uncompressed size
          ..u16(nameBytes.length)
          ..u16(extraLen)
          ..bytes(nameBytes);
    if (aesExtra != null) local.bytes(aesExtra);
    if (zip64Extra != null) local.bytes(zip64Extra);
    await _sink.add(local.take());

    // AES envelope preamble: salt then the 2-byte password verifier.
    if (enc != null) {
      await _sink.add(enc.salt);
      await _sink.add(enc.verifier);
    }

    // Writes compressed output, encrypting it in a fresh buffer when the
    // entry is protected (never mutating the caller's or the deflater's
    // buffers, and keeping the CTR/HMAC in emission order).
    Future<void> emit(Uint8List chunk) async {
      if (chunk.isEmpty) return;
      if (enc != null) {
        final owned = Uint8List.fromList(chunk);
        enc.process(owned);
        await _sink.add(owned);
      } else {
        await _sink.add(chunk);
      }
    }

    // Stream the content: CRC over the uncompressed plaintext, count the
    // compressed bytes (= ciphertext length; the AES overhead is added
    // separately to the recorded size).
    final crc = Crc32();
    var uncompressed = 0;
    var compressed = 0;

    if (method == 0) {
      await for (final chunk in content) {
        uncompressed += chunk.length;
        if (uncompressed > size) {
          throw SizeLimitExceededException(
            'entry "$path" streamed more than the declared size $size',
            limit: size,
            format: 'zip',
            entryPath: path,
          );
        }
        crc.add(chunk);
        compressed += chunk.length;
        await emit(chunk);
      }
    } else {
      final pending = <Uint8List>[];
      final deflater = RawDeflater(
        onOutput: (chunk) {
          compressed += chunk.length;
          pending.add(chunk);
        },
      );
      await for (final chunk in content) {
        uncompressed += chunk.length;
        if (uncompressed > size) {
          throw SizeLimitExceededException(
            'entry "$path" streamed more than the declared size $size',
            limit: size,
            format: 'zip',
            entryPath: path,
          );
        }
        crc.add(chunk);
        deflater.add(chunk);
        for (final out in pending) {
          await emit(out);
        }
        pending.clear();
      }
      deflater.finish();
      for (final out in pending) {
        await emit(out);
      }
    }
    if (uncompressed != size) {
      throw CorruptArchiveException(
        'entry "$path" streamed $uncompressed bytes, declared $size',
        format: 'zip',
        entryPath: path,
      );
    }

    // AES envelope trailer: the 10-byte HMAC-SHA1 authentication tag.
    if (enc != null) {
      await _sink.add(enc.finishMac());
    }

    // The recorded compressed size counts the whole AES envelope (salt +
    // verifier + ciphertext + MAC); AE-2 stores a zero CRC.
    final recordedCompressed = compressed + overhead;
    final recordedCrc = encrypt ? 0 : crc.value;

    // Data descriptor (8-byte sizes when ZIP64).
    final descriptor =
        _ByteWriter()
          ..u32(_descriptorSig)
          ..u32(recordedCrc);
    if (zip64) {
      descriptor
        ..u64(recordedCompressed)
        ..u64(uncompressed);
    } else {
      descriptor
        ..u32(recordedCompressed)
        ..u32(uncompressed);
    }
    await _sink.add(descriptor.take());

    _central.add(
      _CentralRecord(
        nameBytes: nameBytes,
        method: headerMethod,
        crc: recordedCrc,
        compressedSize: recordedCompressed,
        uncompressedSize: uncompressed,
        localOffset: localOffset,
        dosTime: dosTime,
        dosDate: dosDate,
        externalAttributes: _externalAttributes(
          spec,
          isDirectory: isDirectory,
          isSymlink: isSymlink,
        ),
        zip64: zip64,
        aesExtra: aesExtra,
      ),
    );

    return ArchiveEntry(
      path: path,
      type:
          isSymlink
              ? ArchiveEntryType.symlink
              : isDirectory
              ? ArchiveEntryType.directory
              : ArchiveEntryType.file,
      uncompressedSize: uncompressed,
      compressedSize: recordedCompressed,
      compression:
          method == 0 ? ArchiveCompression.stored : ArchiveCompression.deflate,
      isEncrypted: encrypt,
      crc32: crc.value,
      modified: spec.modified,
      posixMode: spec.posixMode,
      linkTarget: isSymlink ? spec.linkTarget : null,
    );
  }

  /// The 0x9901 WinZip AES extra field (11 bytes): header id, 7-byte data
  /// size, AE vendor version, the "AE" vendor id, the strength byte, and the
  /// real compression method, identical bytes for the local and central
  /// records (see `WinZipAesParams.fromExtra`, the read-side inverse).
  static Uint8List _aesExtraField(WinZipAesParams p) =>
      (_ByteWriter()
            ..u16(0x9901)
            ..u16(7)
            ..u16(p.vendorVersion)
            ..bytes(const [0x41, 0x45]) // "AE"
            ..bytes([p.strength])
            ..u16(p.method))
          .take();

  Uint8List _passwordBytes() =>
      Uint8List.fromList(utf8.encode(_options.password!));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    final cdStart = _sink.length;
    for (final record in _central) {
      await _sink.add(_centralRecord(record));
    }
    final cdSize = _sink.length - cdStart;
    final count = _central.length;

    final needsZip64Eocd =
        count > 0xFFFF || cdSize > _u32Max || cdStart > _u32Max;
    if (needsZip64Eocd) {
      final eocd64Offset = _sink.length;
      final eocd64 =
          _ByteWriter()
            ..u32(_eocd64Sig)
            ..u64(44) // size of remaining record
            ..u16(45) // version made by
            ..u16(45) // version needed
            ..u32(0) // this disk
            ..u32(0) // cd start disk
            ..u64(count)
            ..u64(count)
            ..u64(cdSize)
            ..u64(cdStart);
      await _sink.add(eocd64.take());

      final locator =
          _ByteWriter()
            ..u32(_eocd64LocatorSig)
            ..u32(0) // disk with eocd64
            ..u64(eocd64Offset)
            ..u32(1); // total disks
      await _sink.add(locator.take());
    }

    final eocd =
        _ByteWriter()
          ..u32(_eocdSig)
          ..u16(0) // this disk
          ..u16(0) // cd start disk
          ..u16(count > 0xFFFF ? 0xFFFF : count)
          ..u16(count > 0xFFFF ? 0xFFFF : count)
          ..u32(cdSize > _u32Max ? _u32Max : cdSize)
          ..u32(cdStart > _u32Max ? _u32Max : cdStart)
          ..u16(0); // comment length
    await _sink.add(eocd.take());
  }

  Uint8List _centralRecord(_CentralRecord r) {
    final encrypted = r.aesExtra != null;
    final needsZip64 =
        r.zip64 ||
        r.uncompressedSize > _u32Max ||
        r.compressedSize > _u32Max ||
        r.localOffset > _u32Max;
    final extra = _ByteWriter();
    if (needsZip64) {
      final fields = _ByteWriter();
      if (r.uncompressedSize > _u32Max) fields.u64(r.uncompressedSize);
      if (r.compressedSize > _u32Max) fields.u64(r.compressedSize);
      if (r.localOffset > _u32Max) fields.u64(r.localOffset);
      final payload = fields.take();
      extra
        ..u16(0x0001)
        ..u16(payload.length)
        ..bytes(payload);
    }
    if (r.aesExtra != null) extra.bytes(r.aesExtra!);
    final extraBytes = extra.take();

    final versionNeeded =
        encrypted
            ? 51
            : needsZip64
            ? 45
            : 20;
    final w =
        _ByteWriter()
          ..u32(_centralSig)
          ..u16((3 << 8) | versionNeeded) // made by (unix)
          ..u16(versionNeeded) // version needed
          // flags: data descriptor + UTF-8, + bit 0 when encrypted.
          ..u16(encrypted ? 0x0809 : 0x0808)
          ..u16(r.method)
          ..u16(r.dosTime)
          ..u16(r.dosDate)
          ..u32(r.crc)
          ..u32(r.compressedSize > _u32Max ? _u32Max : r.compressedSize)
          ..u32(r.uncompressedSize > _u32Max ? _u32Max : r.uncompressedSize)
          ..u16(r.nameBytes.length)
          ..u16(extraBytes.length)
          ..u16(0) // comment length
          ..u16(0) // disk number start
          ..u16(0) // internal attributes
          ..u32(r.externalAttributes)
          ..u32(r.localOffset > _u32Max ? _u32Max : r.localOffset)
          ..bytes(r.nameBytes)
          ..bytes(extraBytes);
    return w.take();
  }

  int _methodOf(ArchiveEntrySpec spec) {
    final requested = spec.compression ?? _options.compression;
    if (requested == null || requested == ArchiveCompression.deflate) return 8;
    if (requested == ArchiveCompression.stored) return 0;
    throw UnsupportedCompressionException(
      'zip writing supports stored and deflate; "${requested.name}" is not '
      'available',
      methodName: requested.name,
      format: 'zip',
      entryPath: spec.path,
    );
  }

  int _externalAttributes(
    ArchiveEntrySpec spec, {
    required bool isDirectory,
    required bool isSymlink,
  }) {
    var unixMode = spec.posixMode ?? (isDirectory ? 0x1ED : 0x1A4);
    unixMode |=
        isDirectory
            ? 0x4000 // S_IFDIR
            : isSymlink
            ? 0xA000 // S_IFLNK
            : 0x8000; // S_IFREG
    var attrs = unixMode << 16;
    if (isDirectory) attrs |= 0x10; // DOS directory bit
    return attrs;
  }

  void _checkOpen() {
    if (_closed) {
      throw ArchiveClosedException('writer is closed', format: 'zip');
    }
  }

  static List<int> _utf8(String s) => utf8.encode(s);

  static (int, int) _dosDateTime(DateTime? modified) {
    if (modified == null) return (0, 0x21); // 1980-01-01 00:00
    final m = modified;
    if (m.year < 1980) return (0, 0x21);
    final date = ((m.year - 1980) << 9) | (m.month << 5) | m.day;
    final time = (m.hour << 11) | (m.minute << 5) | (m.second ~/ 2);
    return (time & 0xFFFF, date & 0xFFFF);
  }
}

final class _CentralRecord {
  _CentralRecord({
    required this.nameBytes,
    required this.method,
    required this.crc,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localOffset,
    required this.dosTime,
    required this.dosDate,
    required this.externalAttributes,
    required this.zip64,
    this.aesExtra,
  });

  final Uint8List nameBytes;
  final int method;
  final int crc;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;
  final int dosTime;
  final int dosDate;
  final int externalAttributes;
  final bool zip64;

  /// The 0x9901 extra bytes for an encrypted entry, or null when plaintext.
  final Uint8List? aesExtra;
}

/// Little-endian byte assembler for ZIP structures.
final class _ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void u16(int v) => _b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) =>
      _b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u64(int v) {
    u32(v & 0xFFFFFFFF);
    u32(v ~/ 0x100000000);
  }

  void bytes(List<int> data) => _b.add(data);

  Uint8List take() => _b.takeBytes();
}
