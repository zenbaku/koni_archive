import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'header.dart';
import 'pax.dart';

/// Chunk size for streaming entry content out of the source.
const int _readChunkSize = 64 * 1024;

/// Sanity cap for metadata blobs a header can ask us to buffer (PAX record
/// data, GNU long names). Real-world values are well under a block or two;
/// 1 MiB is generous while keeping attacker-controlled allocations bounded.
const int _maxMetadataSize = 1024 * 1024;

/// Reader for POSIX/GNU tar archives. Created via `TarFormat.openReader`.
final class TarReader extends ArchiveReader {
  TarReader._(this.format, this._source, this._entries, this._info);

  @override
  final ArchiveFormat format;

  final ByteSource _source;
  final List<ArchiveEntry> _entries;

  /// Parallel bookkeeping per entry index: where the data lives, and why
  /// content is unreadable (sparse), if so.
  final List<_EntryInfo> _info;

  final Expando<int> _indexOf = Expando<int>();
  bool _closed = false;

  @override
  List<ArchiveEntry> get entries => _entries;

  /// Walks every header block eagerly and builds the index: O(entry
  /// count), no content reads (note the caveat documented in
  /// `doc/notes.md`: indexing a TAR inherently touches a header every 512+
  /// bytes across the whole file).
  static Future<TarReader> parse(
    ArchiveFormat format,
    ByteSource source,
  ) async {
    final entries = <ArchiveEntry>[];
    final info = <_EntryInfo>[];

    var globalPax = const <String, String>{};
    Map<String, String>? pendingPax;
    String? pendingLongName;
    String? pendingLongLink;

    var offset = 0;
    var zeroBlocks = 0;
    while (offset + tarBlockSize <= source.length) {
      final block = await source.read(offset, tarBlockSize);
      final header = TarHeader.parse(block, offset);
      if (header == null) {
        zeroBlocks++;
        offset += tarBlockSize;
        if (zeroBlocks >= 2) break; // end-of-archive marker
        continue;
      }
      // A lone zero block followed by a real header is tolerated (some
      // writers pad oddly); two in a row ended the archive above.
      zeroBlocks = 0;

      final dataOffset = offset + tarBlockSize;
      final dataBlocks = (header.size + tarBlockSize - 1) ~/ tarBlockSize;

      switch (header.typeFlag) {
        case 0x78 /* x: PAX per-file */ :
          pendingPax = parsePaxRecords(
            await _readMetadata(source, dataOffset, header.size, offset),
            dataOffset,
          );
          offset = dataOffset + dataBlocks * tarBlockSize;
          continue;

        case 0x67 /* g: PAX global */ :
          globalPax = {
            ...globalPax,
            ...parsePaxRecords(
              await _readMetadata(source, dataOffset, header.size, offset),
              dataOffset,
            ),
          };
          offset = dataOffset + dataBlocks * tarBlockSize;
          continue;

        case 0x4C /* L: GNU long name */ :
          pendingLongName = _decodeGnuLongString(
            await _readMetadata(source, dataOffset, header.size, offset),
          );
          offset = dataOffset + dataBlocks * tarBlockSize;
          continue;

        case 0x4B /* K: GNU long link */ :
          pendingLongLink = _decodeGnuLongString(
            await _readMetadata(source, dataOffset, header.size, offset),
          );
          offset = dataOffset + dataBlocks * tarBlockSize;
          continue;
      }

      // Old-GNU sparse ('S'): skip continuation blocks so the walk stays on
      // track; content is exposed as unreadable (typed error at openRead).
      var sparseExtensionBlocks = 0;
      if (header.typeFlag == 0x53 && header.gnuSparseIsExtended) {
        var extOffset = dataOffset;
        while (true) {
          if (extOffset + tarBlockSize > source.length) {
            throw UnexpectedEofException(
              'truncated GNU sparse extension blocks',
              format: 'tar',
              offset: extOffset,
            );
          }
          final ext = await source.read(extOffset, tarBlockSize);
          sparseExtensionBlocks++;
          extOffset += tarBlockSize;
          if (ext[504] == 0) break; // isextended flag of the extension block
        }
      }

      final pax = {...globalPax, ...?pendingPax};
      final entryDataOffset = dataOffset + sparseExtensionBlocks * tarBlockSize;

      // Effective metadata: PAX beats GNU long name/link beats header field.
      final rawPath = pax['path'] ?? pendingLongName ?? header.fullName;
      final rawLink = pax['linkpath'] ?? pendingLongLink ?? header.linkName;
      final size = _paxInt(pax['size']) ?? header.size;
      if (size < 0) {
        throw InvalidHeaderException(
          'negative PAX size',
          format: 'tar',
          offset: offset,
        );
      }

      final type = _entryType(header.typeFlag, rawPath);
      // Link/dir/device entries carry no data blocks regardless of their
      // size field (GNU/bsdtar behavior; see doc/notes.md). Sparse and
      // unknown flags conservatively consume ceil(size/512).
      final consumesData =
          type == ArchiveEntryType.file || !_isLinkOrSpecial(header.typeFlag);
      final storedDataBlocks =
          consumesData
              ? ((header.typeFlag == 0x53 ? header.size : size) +
                      tarBlockSize -
                      1) ~/
                  tarBlockSize
              : 0;

      if (consumesData &&
          entryDataOffset + storedDataBlocks * tarBlockSize > source.length) {
        // Tolerate an unpadded final entry (data present but padding
        // missing), like bsdtar; anything shorter is truncation.
        final available = source.length - entryDataOffset;
        final needed = header.typeFlag == 0x53 ? header.size : size;
        if (available < needed) {
          throw UnexpectedEofException(
            'entry data extends past the end of the archive',
            format: 'tar',
            offset: offset,
            entryPath: rawPath,
          );
        }
      }

      final normalized = normalizeEntryPath(rawPath);
      final mtime =
          pax.containsKey('mtime')
              ? parsePaxTime(pax['mtime']!)
              : _headerTime(header.mtime);

      String? unsupportedReason;
      if (header.typeFlag == 0x53) {
        unsupportedReason = 'GNU sparse entries are not supported yet';
      } else if (pax.keys.any((k) => k.startsWith('GNU.sparse.'))) {
        unsupportedReason = 'PAX (GNU) sparse entries are not supported yet';
      }

      final entry = ArchiveEntry(
        path: normalized.path,
        pathEscapedRoot: normalized.escapedRoot,
        type: type,
        uncompressedSize: size,
        compressedSize: null, // tar records no compressed size
        modified: mtime,
        linkTarget:
            (type == ArchiveEntryType.symlink ||
                    type == ArchiveEntryType.hardlink)
                ? rawLink
                : null,
        posixMode: header.mode,
      );
      entries.add(entry);
      info.add(
        _EntryInfo(
          dataOffset: entryDataOffset,
          dataLength: consumesData ? size : 0,
          unsupportedReason: unsupportedReason,
        ),
      );

      pendingPax = null;
      pendingLongName = null;
      pendingLongLink = null;
      offset = entryDataOffset + storedDataBlocks * tarBlockSize;
    }

    if (entries.isEmpty && offset == 0 && source.length > 0) {
      throw InvalidHeaderException(
        'no tar header found',
        format: 'tar',
        offset: 0,
      );
    }

    final reader = TarReader._(
      format,
      source,
      List.unmodifiable(entries),
      info,
    );
    for (var i = 0; i < entries.length; i++) {
      reader._indexOf[entries[i]] = i;
    }
    return reader;
  }

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    final index = _indexOf[entry];
    if (index == null) {
      throw ArgumentError.value(entry, 'entry', 'not an entry of this archive');
    }
    final info = _info[index];
    if (info.unsupportedReason != null) {
      throw UnsupportedFeatureException(
        info.unsupportedReason!,
        format: 'tar',
        entryPath: entry.path,
      );
    }
    return _streamRange(info.dataOffset, info.dataLength, entry.path);
  }

  Stream<Uint8List> _streamRange(
    int start,
    int length,
    String entryPath,
  ) async* {
    var remaining = length;
    var offset = start;
    while (remaining > 0) {
      if (_closed) {
        throw ArchiveClosedException(
          'archive was closed while streaming entry',
          format: 'tar',
          entryPath: entryPath,
        );
      }
      final chunkSize = remaining < _readChunkSize ? remaining : _readChunkSize;
      final chunk = await _source.read(offset, chunkSize);
      offset += chunkSize;
      remaining -= chunkSize;
      yield chunk;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  static Future<Uint8List> _readMetadata(
    ByteSource source,
    int offset,
    int size,
    int headerOffset,
  ) {
    if (size > _maxMetadataSize) {
      throw InvalidHeaderException(
        'metadata entry claims implausible size $size',
        format: 'tar',
        offset: headerOffset,
      );
    }
    return source.read(offset, size);
  }

  static String _decodeGnuLongString(Uint8List data) {
    // NUL-terminated within the data area.
    var end = data.length;
    while (end > 0 && data[end - 1] == 0) {
      end--;
    }
    return decodeTarString(data, 0, end);
  }

  static int? _paxInt(String? value) =>
      value == null ? null : int.tryParse(value.trim());

  static DateTime? _headerTime(int? mtime) {
    // Hostile base-256 mtimes can exceed DateTime's range; timestamps are
    // best-effort metadata, so out-of-range becomes null (fuzz invariant:
    // no ArgumentError). Bound: years 0001-9999.
    if (mtime == null || mtime < -62135596800 || mtime > 253402300799) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true);
  }

  static ArchiveEntryType _entryType(int typeFlag, String rawPath) {
    switch (typeFlag) {
      case 0x00:
      case 0x30 /* '0' */ :
        // Pre-POSIX convention: a trailing slash marks a directory.
        return rawPath.endsWith('/')
            ? ArchiveEntryType.directory
            : ArchiveEntryType.file;
      case 0x31 /* '1' */ :
        return ArchiveEntryType.hardlink;
      case 0x32 /* '2' */ :
        return ArchiveEntryType.symlink;
      case 0x33 /* '3' */ :
        return ArchiveEntryType.characterDevice;
      case 0x34 /* '4' */ :
        return ArchiveEntryType.blockDevice;
      case 0x35 /* '5' */ :
        return ArchiveEntryType.directory;
      case 0x36 /* '6' */ :
        return ArchiveEntryType.fifo;
      case 0x37 /* '7': contiguous file, treated as regular */ :
      case 0x53 /* 'S': GNU sparse (content unsupported) */ :
        return ArchiveEntryType.file;
      default:
        return ArchiveEntryType.other;
    }
  }

  static bool _isLinkOrSpecial(int typeFlag) {
    switch (typeFlag) {
      case 0x31: // hardlink
      case 0x32: // symlink
      case 0x33: // char device
      case 0x34: // block device
      case 0x35: // directory
      case 0x36: // fifo
        return true;
      default:
        return false;
    }
  }
}

final class _EntryInfo {
  _EntryInfo({
    required this.dataOffset,
    required this.dataLength,
    this.unsupportedReason,
  });

  final int dataOffset;
  final int dataLength;
  final String? unsupportedReason;
}
