import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'header.dart' show tarBlockSize;

/// Writer for POSIX tar archives (ustar, with PAX extended headers when a
/// field does not fit). Created via `TarWriteFormat.openWriter`.
///
/// Emits ustar by default; a PAX (`x`) extended header precedes an entry
/// whose path or link target exceeds the ustar fields, or whose size
/// exceeds the 11-octal-digit limit (~8 GiB). The field encoding mirrors
/// the reader's (see `doc/notes.md`).
final class TarWriter extends ArchiveWriter {
  /// Creates a writer appending to [_sink].
  TarWriter(this.format, this._sink);

  @override
  final ArchiveWriteFormat format;

  final ByteSink _sink;
  bool _closed = false;
  var _paxCounter = 0;

  // Type flags.
  static const int _typeFile = 0x30; // '0'
  static const int _typeHardlink = 0x31; // '1'
  static const int _typeSymlink = 0x32; // '2'
  static const int _typeChar = 0x33; // '3'
  static const int _typeBlock = 0x34; // '4'
  static const int _typeDir = 0x35; // '5'
  static const int _typeFifo = 0x36; // '6'
  static const int _typePax = 0x78; // 'x'

  /// Largest size that fits ustar's 11 octal digits.
  static const int _maxUstarSize = 0x1FFFFFFFF; // 0o77777777777 == 8 GiB - 1

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
    _rejectCompression(spec);
    final path = validateWritePath(spec.path);

    await _writeHeader(spec, path, size, _typeFile, '');

    final crc = Crc32();
    var written = 0;
    await for (final chunk in content) {
      written += chunk.length;
      if (written > size) {
        throw SizeLimitExceededException(
          'entry "$path" streamed more than the declared size $size',
          limit: size,
          format: 'tar',
          entryPath: path,
        );
      }
      crc.add(chunk);
      await _sink.add(chunk);
    }
    if (written != size) {
      throw CorruptArchiveException(
        'entry "$path" streamed $written bytes, declared $size',
        format: 'tar',
        entryPath: path,
      );
    }
    await _pad(size);

    return ArchiveEntry(
      path: path,
      type: ArchiveEntryType.file,
      uncompressedSize: size,
      crc32: crc.value,
      modified: spec.modified,
      posixMode: spec.posixMode,
    );
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
    _rejectCompression(spec);
    final path = validateWritePath(spec.path);
    final linkTarget = spec.linkTarget ?? '';
    final typeFlag = switch (spec.type) {
      ArchiveEntryType.directory => _typeDir,
      ArchiveEntryType.symlink => _typeSymlink,
      ArchiveEntryType.hardlink => _typeHardlink,
      ArchiveEntryType.fifo => _typeFifo,
      ArchiveEntryType.characterDevice => _typeChar,
      ArchiveEntryType.blockDevice => _typeBlock,
      _ => _typeFile,
    };
    await _writeHeader(spec, path, 0, typeFlag, linkTarget);
    return ArchiveEntry(
      path: path,
      type: spec.type,
      uncompressedSize: 0,
      modified: spec.modified,
      posixMode: spec.posixMode,
      linkTarget:
          spec.type == ArchiveEntryType.symlink ||
                  spec.type == ArchiveEntryType.hardlink
              ? spec.linkTarget
              : null,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Two zero blocks mark the end of the archive.
    await _sink.add(Uint8List(tarBlockSize * 2));
  }

  void _checkOpen() {
    if (_closed) {
      throw ArchiveClosedException('writer is closed', format: 'tar');
    }
  }

  void _rejectCompression(ArchiveEntrySpec spec) {
    final compression = spec.compression;
    if (compression != null && compression != ArchiveCompression.stored) {
      throw UnsupportedCompressionException(
        'tar entries are always stored; "${compression.name}" is not '
        'applicable',
        methodName: compression.name,
        format: 'tar',
        entryPath: spec.path,
      );
    }
  }

  /// Writes an entry header, emitting a preceding PAX header when needed.
  Future<void> _writeHeader(
    ArchiveEntrySpec spec,
    String path,
    int size,
    int typeFlag,
    String linkTarget,
  ) async {
    // Directories carry a trailing slash by ustar convention.
    var ustarName = typeFlag == _typeDir ? '$path/' : path;

    final paxRecords = <String, String>{};
    final (prefix, shortName) = _splitUstarName(ustarName);
    if (prefix == null) {
      // The name does not fit ustar's name+prefix fields: record it in PAX
      // and store a best-effort truncated name in the header.
      paxRecords['path'] = ustarName;
      ustarName = _truncateUtf8(ustarName, 100);
    }

    final linkBytes = utf8.encode(linkTarget);
    var ustarLink = linkTarget;
    if (linkBytes.length > 100) {
      paxRecords['linkpath'] = linkTarget;
      ustarLink = _truncateUtf8(linkTarget, 100);
    }

    var ustarSize = size;
    if (size > _maxUstarSize) {
      paxRecords['size'] = '$size';
      ustarSize = 0; // ustar size field left zero; PAX carries the real one
    }

    if (paxRecords.isNotEmpty) {
      await _writePaxHeader(paxRecords, spec);
    }

    final block = Uint8List(tarBlockSize);
    if (prefix != null && prefix.isNotEmpty) {
      _putString(block, 0, 100, shortName);
      _putString(block, 345, 155, prefix);
    } else {
      _putString(block, 0, 100, ustarName);
    }
    _putOctal(block, 100, 8, spec.posixMode ?? _defaultMode(typeFlag));
    _putOctal(block, 108, 8, 0); // uid
    _putOctal(block, 116, 8, 0); // gid
    _putOctal(block, 124, 12, ustarSize);
    _putOctal(block, 136, 12, _unixSeconds(spec.modified));
    block[156] = typeFlag;
    _putString(block, 157, 100, ustarLink);
    _putString(block, 257, 8, 'ustar\x0000'); // magic + version
    _putChecksum(block);
    await _sink.add(block);
  }

  Future<void> _writePaxHeader(
    Map<String, String> records,
    ArchiveEntrySpec spec,
  ) async {
    final payload = BytesBuilder(copy: false);
    for (final MapEntry(key: key, value: value) in records.entries) {
      payload.add(Uint8List.fromList(utf8.encode(_paxRecord(key, value))));
    }
    final data = payload.takeBytes();

    final block = Uint8List(tarBlockSize);
    // A short, valid ustar name for the PAX header itself.
    _putString(block, 0, 100, 'PaxHeaders/${_paxCounter++}');
    _putOctal(block, 100, 8, 0x1A4); // 0644
    _putOctal(block, 108, 8, 0);
    _putOctal(block, 116, 8, 0);
    _putOctal(block, 124, 12, data.length);
    _putOctal(block, 136, 12, _unixSeconds(spec.modified));
    block[156] = _typePax;
    _putString(block, 257, 8, 'ustar\x0000');
    _putChecksum(block);
    await _sink.add(block);
    await _sink.add(data);
    await _pad(data.length);
  }

  /// Builds one PAX record: `"<len> <key>=<value>\n"` where len counts the
  /// whole record including its own digits.
  static String _paxRecord(String key, String value) {
    final payloadLength = utf8.encode(' $key=$value\n').length;
    var length = payloadLength + 1;
    while ('$length'.length + payloadLength != length) {
      length = '$length'.length + payloadLength;
    }
    return '$length $key=$value\n';
  }

  /// Splits [name] into (prefix, shortName) for ustar, or (null, name) when
  /// it does not fit. Both parts must be within their byte limits and the
  /// split must fall on a `/`.
  static (String?, String) _splitUstarName(String name) {
    final bytes = utf8.encode(name);
    if (bytes.length <= 100) return ('', name); // fits the name field alone
    // Search for a split point: prefix ≤ 155 bytes, name ≤ 100 bytes.
    for (var i = name.length - 1; i > 0; i--) {
      if (name[i] != '/') continue;
      final prefix = name.substring(0, i);
      final rest = name.substring(i + 1);
      if (utf8.encode(prefix).length <= 155 &&
          utf8.encode(rest).length <= 100 &&
          rest.isNotEmpty) {
        return (prefix, rest);
      }
    }
    return (null, name);
  }

  static String _truncateUtf8(String value, int maxBytes) {
    var end = value.length;
    while (end > 0 && utf8.encode(value.substring(0, end)).length > maxBytes) {
      end--;
    }
    return value.substring(0, end);
  }

  Future<void> _pad(int dataLength) async {
    final remainder = dataLength % tarBlockSize;
    if (remainder != 0) {
      await _sink.add(Uint8List(tarBlockSize - remainder));
    }
  }

  static int _defaultMode(int typeFlag) => typeFlag == _typeDir ? 0x1ED : 0x1A4;

  static int _unixSeconds(DateTime? modified) {
    if (modified == null) return 0;
    final seconds = modified.millisecondsSinceEpoch ~/ 1000;
    return seconds < 0 ? 0 : seconds;
  }

  static void _putString(Uint8List block, int at, int length, String value) {
    final bytes = utf8.encode(value);
    final n = bytes.length > length ? length : bytes.length;
    block.setRange(at, at + n, bytes);
  }

  static void _putOctal(Uint8List block, int at, int length, int value) {
    // <octal digits, zero-padded to length-1> + NUL.
    final digits = value.toRadixString(8);
    final field = digits.padLeft(length - 1, '0');
    final bytes = ascii.encode(field);
    final start = at + (length - 1) - bytes.length;
    block.setRange(start, at + length - 1, bytes);
    block[at + length - 1] = 0;
  }

  static void _putChecksum(Uint8List block) {
    for (var i = 148; i < 156; i++) {
      block[i] = 0x20; // spaces during computation
    }
    var sum = 0;
    for (final byte in block) {
      sum += byte;
    }
    final digits = sum.toRadixString(8).padLeft(6, '0');
    block.setRange(148, 154, ascii.encode(digits));
    block[154] = 0;
    block[155] = 0x20;
  }
}
