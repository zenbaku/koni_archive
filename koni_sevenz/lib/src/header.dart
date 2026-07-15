/// 7z header parsing, per the `7zFormat.txt` description shipped with the
/// public-domain LZMA SDK.
library;

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

/// Property ids of the 7z header grammar.
abstract final class SevenZId {
  /// kEnd — terminates a property block.
  static const int end = 0x00;

  /// kHeader — the uncompressed archive header.
  static const int header = 0x01;

  /// kArchiveProperties.
  static const int archiveProperties = 0x02;

  /// kAdditionalStreamsInfo.
  static const int additionalStreamsInfo = 0x03;

  /// kMainStreamsInfo.
  static const int mainStreamsInfo = 0x04;

  /// kFilesInfo.
  static const int filesInfo = 0x05;

  /// kPackInfo.
  static const int packInfo = 0x06;

  /// kUnpackInfo.
  static const int unpackInfo = 0x07;

  /// kSubStreamsInfo.
  static const int subStreamsInfo = 0x08;

  /// kSize.
  static const int size = 0x09;

  /// kCRC.
  static const int crc = 0x0A;

  /// kFolder.
  static const int folder = 0x0B;

  /// kCodersUnpackSize.
  static const int codersUnpackSize = 0x0C;

  /// kNumUnpackStream.
  static const int numUnpackStream = 0x0D;

  /// kEmptyStream.
  static const int emptyStream = 0x0E;

  /// kEmptyFile.
  static const int emptyFile = 0x0F;

  /// kAnti (anti-files in incremental archives).
  static const int anti = 0x10;

  /// kName.
  static const int name = 0x11;

  /// kCTime.
  static const int cTime = 0x12;

  /// kATime.
  static const int aTime = 0x13;

  /// kMTime.
  static const int mTime = 0x14;

  /// kWinAttributes.
  static const int winAttributes = 0x15;

  /// kEncodedHeader — the header itself is folder-compressed.
  static const int encodedHeader = 0x17;

  /// kStartPos.
  static const int startPos = 0x18;

  /// kDummy — padding.
  static const int dummy = 0x19;
}

/// Reads 7z's variable-length number encoding (first byte's high bits give
/// the length). Values beyond 2^53 − 1 throw (uniform cap, §7).
int readSevenZipNumber(ByteReader reader) {
  final first = reader.readUint8();
  var mask = 0x80;
  var value = 0;
  var scale = 1;
  for (var i = 0; i < 8; i++) {
    if ((first & mask) == 0) {
      // Remaining low bits of the first byte form the highest part.
      final result = value + (first & (mask - 1)) * scale;
      if (result > 0x1FFFFFFFFFFFFF) {
        throw UnsupportedFeatureException(
          'number exceeds the supported integer range (2^53 - 1)',
          format: '7z',
        );
      }
      return result;
    }
    value += reader.readUint8() * scale;
    scale *= 256;
    if (value > 0x1FFFFFFFFFFFFF) {
      throw UnsupportedFeatureException(
        'number exceeds the supported integer range (2^53 - 1)',
        format: '7z',
      );
    }
    mask >>= 1;
  }
  return value;
}

/// Reads a bit vector of [count] bits (MSB-first within each byte).
List<bool> readBitVector(ByteReader reader, int count) {
  final bits = List<bool>.filled(count, false);
  var byte = 0;
  var mask = 0;
  for (var i = 0; i < count; i++) {
    if (mask == 0) {
      byte = reader.readUint8();
      mask = 0x80;
    }
    bits[i] = (byte & mask) != 0;
    mask >>= 1;
  }
  return bits;
}

/// Reads a bit vector that may be replaced by an "all defined" marker.
List<bool> readAllOrBits(ByteReader reader, int count) {
  final allDefined = reader.readUint8();
  if (allDefined != 0) return List<bool>.filled(count, true);
  return readBitVector(reader, count);
}

/// A digests block: which streams have CRCs, and their values.
final class SevenZDigests {
  /// Creates a digests block.
  SevenZDigests(this.defined, this.values);

  /// Whether each stream has a CRC.
  final List<bool> defined;

  /// CRC-32 per stream (null when undefined).
  final List<int?> values;

  /// Reads a digests block covering [count] streams.
  static SevenZDigests read(ByteReader reader, int count) {
    final defined = readAllOrBits(reader, count);
    final values = List<int?>.filled(count, null);
    for (var i = 0; i < count; i++) {
      if (defined[i]) values[i] = reader.readUint32le();
    }
    return SevenZDigests(defined, values);
  }
}

/// One coder of a folder: codec id, stream counts, and properties.
final class SevenZCoder {
  /// Creates a coder description.
  SevenZCoder({
    required this.id,
    required this.numInStreams,
    required this.numOutStreams,
    required this.props,
  });

  /// Raw codec id bytes (e.g. `03 01 01` = LZMA).
  final Uint8List id;

  /// Number of input streams this coder consumes.
  final int numInStreams;

  /// Number of output streams this coder produces.
  final int numOutStreams;

  /// Codec properties blob (e.g. LZMA's 5 bytes).
  final Uint8List props;

  /// Codec id as a hex string (`030101` = LZMA) for diagnostics.
  String get idHex => id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// A folder: a small DAG of coders turning packed streams into one output.
final class SevenZFolder {
  /// Creates a folder description.
  SevenZFolder({
    required this.coders,
    required this.bindPairs,
    required this.packedIndices,
    required this.unpackSizes,
  });

  /// The folder's coders, in header order.
  final List<SevenZCoder> coders;

  /// Pairs of (inStreamIndex, outStreamIndex), global across coders.
  final List<(int, int)> bindPairs;

  /// For each packed stream the folder consumes: the global in-stream index.
  final List<int> packedIndices;

  /// Unpack size of every coder out-stream, in global out-stream order.
  final List<int> unpackSizes;

  /// CRC-32 of the folder's full output, when recorded.
  int? crc;

  /// The folder's final output size (the out stream not bound as any
  /// coder's input).
  int get unpackSize => unpackSizes[findMainOutStream()];

  /// Global index of the unbound out stream.
  int findMainOutStream() {
    var outIndex = 0;
    for (var i = 0; i < unpackSizes.length; i++) {
      if (!bindPairs.any((p) => p.$2 == i)) {
        outIndex = i;
      }
    }
    return outIndex;
  }

  /// Reads one folder definition.
  static SevenZFolder read(ByteReader reader) {
    final numCoders = readSevenZipNumber(reader);
    if (numCoders == 0 || numCoders > 64) {
      throw InvalidHeaderException(
        'implausible coder count $numCoders in folder',
        format: '7z',
      );
    }
    final coders = <SevenZCoder>[];
    var totalIn = 0;
    var totalOut = 0;
    for (var i = 0; i < numCoders; i++) {
      final flags = reader.readUint8();
      final idSize = flags & 0x0F;
      final isComplex = flags & 0x10 != 0;
      final hasAttrs = flags & 0x20 != 0;
      if (flags & 0x80 != 0) {
        throw UnsupportedFeatureException(
          'alternative coder methods are not supported',
          format: '7z',
        );
      }
      final id = Uint8List.fromList(reader.readBytes(idSize));
      var numIn = 1;
      var numOut = 1;
      if (isComplex) {
        numIn = readSevenZipNumber(reader);
        numOut = readSevenZipNumber(reader);
      }
      var props = Uint8List(0);
      if (hasAttrs) {
        final propsSize = readSevenZipNumber(reader);
        if (propsSize > 1024 * 1024) {
          throw InvalidHeaderException(
            'implausible coder properties size $propsSize',
            format: '7z',
          );
        }
        props = Uint8List.fromList(reader.readBytes(propsSize));
      }
      coders.add(
        SevenZCoder(
          id: id,
          numInStreams: numIn,
          numOutStreams: numOut,
          props: props,
        ),
      );
      totalIn += numIn;
      totalOut += numOut;
    }
    final numBindPairs = totalOut - 1;
    final bindPairs = <(int, int)>[];
    for (var i = 0; i < numBindPairs; i++) {
      bindPairs.add((readSevenZipNumber(reader), readSevenZipNumber(reader)));
    }
    final numPacked = totalIn - numBindPairs;
    final packedIndices = <int>[];
    if (numPacked == 1) {
      // The single in-stream not used by any bind pair.
      var index = 0;
      for (var i = 0; i < totalIn; i++) {
        if (!bindPairs.any((p) => p.$1 == i)) {
          index = i;
          break;
        }
      }
      packedIndices.add(index);
    } else {
      for (var i = 0; i < numPacked; i++) {
        packedIndices.add(readSevenZipNumber(reader));
      }
    }
    return SevenZFolder(
      coders: coders,
      bindPairs: bindPairs,
      packedIndices: packedIndices,
      unpackSizes: [], // filled by kCodersUnpackSize
    );
  }
}

/// Parsed pack/unpack/substream information.
final class SevenZStreamsInfo {
  /// Creates a streams-info description.
  SevenZStreamsInfo({
    required this.packPos,
    required this.packSizes,
    required this.folders,
    required this.numUnpackStreams,
    required this.substreamSizes,
    required this.substreamCrcs,
  });

  /// Offset of the packed area, relative to the end of the signature
  /// header (byte 32).
  final int packPos;

  /// Sizes of the packed streams, in order.
  final List<int> packSizes;

  /// The folders (solid blocks).
  final List<SevenZFolder> folders;

  /// Substream count per folder (default 1).
  final List<int> numUnpackStreams;

  /// Sizes of all substreams, folder-major order.
  final List<int> substreamSizes;

  /// CRC-32 per substream where known.
  final List<int?> substreamCrcs;

  /// For each folder: index of its first packed stream in [packSizes].
  List<int> packStreamStarts() {
    final starts = <int>[];
    var index = 0;
    for (final folder in folders) {
      starts.add(index);
      index += folder.packedIndices.length;
    }
    return starts;
  }

  /// Reads a StreamsInfo block (PackInfo + UnpackInfo + SubStreamsInfo).
  static SevenZStreamsInfo read(ByteReader reader) {
    var packPos = 0;
    var packSizes = <int>[];
    var folders = <SevenZFolder>[];

    var id = readSevenZipNumber(reader);

    if (id == SevenZId.packInfo) {
      packPos = readSevenZipNumber(reader);
      final numPack = readSevenZipNumber(reader);
      if (numPack > reader.length) {
        throw InvalidHeaderException(
          'implausible packed-stream count $numPack',
          format: '7z',
        );
      }
      var inner = readSevenZipNumber(reader);
      while (inner != SevenZId.end) {
        if (inner == SevenZId.size) {
          packSizes = [
            for (var i = 0; i < numPack; i++) readSevenZipNumber(reader),
          ];
        } else if (inner == SevenZId.crc) {
          SevenZDigests.read(reader, numPack); // pack CRCs: unused
        } else {
          throw InvalidHeaderException(
            'unexpected id $inner in PackInfo',
            format: '7z',
          );
        }
        inner = readSevenZipNumber(reader);
      }
      id = readSevenZipNumber(reader);
    }

    if (id == SevenZId.unpackInfo) {
      var inner = readSevenZipNumber(reader);
      if (inner != SevenZId.folder) {
        throw InvalidHeaderException(
          'UnpackInfo without folders',
          format: '7z',
        );
      }
      final numFolders = readSevenZipNumber(reader);
      if (numFolders > reader.length) {
        throw InvalidHeaderException(
          'implausible folder count $numFolders',
          format: '7z',
        );
      }
      final external = reader.readUint8();
      if (external != 0) {
        throw UnsupportedFeatureException(
          'external folder definitions are not supported',
          format: '7z',
        );
      }
      folders = [
        for (var i = 0; i < numFolders; i++) SevenZFolder.read(reader),
      ];
      inner = readSevenZipNumber(reader);
      if (inner != SevenZId.codersUnpackSize) {
        throw InvalidHeaderException(
          'UnpackInfo without coder unpack sizes',
          format: '7z',
        );
      }
      for (final folder in folders) {
        final totalOut = folder.coders.fold<int>(
          0,
          (sum, c) => sum + c.numOutStreams,
        );
        folder.unpackSizes.addAll([
          for (var i = 0; i < totalOut; i++) readSevenZipNumber(reader),
        ]);
      }
      inner = readSevenZipNumber(reader);
      while (inner != SevenZId.end) {
        if (inner == SevenZId.crc) {
          final digests = SevenZDigests.read(reader, folders.length);
          for (var i = 0; i < folders.length; i++) {
            folders[i].crc = digests.values[i];
          }
        } else {
          throw InvalidHeaderException(
            'unexpected id $inner in UnpackInfo',
            format: '7z',
          );
        }
        inner = readSevenZipNumber(reader);
      }
      id = readSevenZipNumber(reader);
    }

    var numUnpackStreams = List<int>.filled(folders.length, 1);
    var substreamSizes = <int>[];
    var substreamCrcs = <int?>[];
    var haveSizes = false;

    if (id == SevenZId.subStreamsInfo) {
      var inner = readSevenZipNumber(reader);
      if (inner == SevenZId.numUnpackStream) {
        numUnpackStreams = [
          for (var i = 0; i < folders.length; i++) readSevenZipNumber(reader),
        ];
        inner = readSevenZipNumber(reader);
      }
      if (inner == SevenZId.size) {
        for (var f = 0; f < folders.length; f++) {
          final count = numUnpackStreams[f];
          if (count == 0) continue;
          var sum = 0;
          for (var i = 0; i < count - 1; i++) {
            final size = readSevenZipNumber(reader);
            substreamSizes.add(size);
            sum += size;
          }
          substreamSizes.add(folders[f].unpackSize - sum);
        }
        haveSizes = true;
        inner = readSevenZipNumber(reader);
      }
      if (inner == SevenZId.crc) {
        // Digests are stored only for substreams whose CRC is not already
        // implied by a single-stream folder's CRC.
        final totalStreams = numUnpackStreams.fold<int>(0, (a, b) => a + b);
        var unknownCount = 0;
        for (var f = 0; f < folders.length; f++) {
          if (numUnpackStreams[f] == 1 && folders[f].crc != null) continue;
          unknownCount += numUnpackStreams[f];
        }
        final digests = SevenZDigests.read(reader, unknownCount);
        substreamCrcs = List<int?>.filled(totalStreams, null);
        var stream = 0;
        var digest = 0;
        for (var f = 0; f < folders.length; f++) {
          if (numUnpackStreams[f] == 1 && folders[f].crc != null) {
            substreamCrcs[stream++] = folders[f].crc;
          } else {
            for (var i = 0; i < numUnpackStreams[f]; i++) {
              substreamCrcs[stream++] = digests.values[digest++];
            }
          }
        }
        inner = readSevenZipNumber(reader);
      }
      if (inner != SevenZId.end) {
        throw InvalidHeaderException(
          'unexpected id $inner in SubStreamsInfo',
          format: '7z',
        );
      }
      id = readSevenZipNumber(reader);
    }

    if (id != SevenZId.end) {
      throw InvalidHeaderException(
        'unexpected id $id at end of StreamsInfo',
        format: '7z',
      );
    }

    if (!haveSizes) {
      // Defaults: one substream per folder, size = folder size.
      substreamSizes = [for (final f in folders) f.unpackSize];
    }
    if (substreamCrcs.isEmpty) {
      substreamCrcs = List<int?>.filled(substreamSizes.length, null);
      var stream = 0;
      for (var f = 0; f < folders.length; f++) {
        for (var i = 0; i < numUnpackStreams[f]; i++) {
          substreamCrcs[stream++] =
              numUnpackStreams[f] == 1 ? folders[f].crc : null;
        }
      }
    }

    return SevenZStreamsInfo(
      packPos: packPos,
      packSizes: packSizes,
      folders: folders,
      numUnpackStreams: numUnpackStreams,
      substreamSizes: substreamSizes,
      substreamCrcs: substreamCrcs,
    );
  }
}

/// Per-file metadata out of FilesInfo.
final class SevenZFileInfo {
  /// Creates an empty holder for [count] files.
  SevenZFileInfo(this.count);

  /// Number of files (including directories and empty files).
  final int count;

  /// Per file: has no content stream (directory or empty file).
  List<bool> emptyStream = [];

  /// Per empty-stream file: is an empty *file* (not a directory).
  List<bool> emptyFile = [];

  /// File names (UTF-16 decoded), in file order.
  List<String> names = [];

  /// Modification times, in file order.
  List<DateTime?> mTimes = [];

  /// Windows attribute words, in file order.
  List<int?> attributes = [];

  /// Reads a FilesInfo block.
  static SevenZFileInfo read(ByteReader reader) {
    final numFiles = readSevenZipNumber(reader);
    if (numFiles > reader.length * 8) {
      throw InvalidHeaderException(
        'implausible file count $numFiles',
        format: '7z',
      );
    }
    final info = SevenZFileInfo(numFiles);
    var numEmptyStreams = 0;
    for (;;) {
      final type = readSevenZipNumber(reader);
      if (type == SevenZId.end) break;
      final size = readSevenZipNumber(reader);
      final end = reader.position + size;
      if (size > reader.remaining) {
        throw UnexpectedEofException(
          'FilesInfo property extends past the header',
          format: '7z',
        );
      }
      switch (type) {
        case SevenZId.emptyStream:
          info.emptyStream = readBitVector(reader, numFiles);
          numEmptyStreams = info.emptyStream.where((b) => b).length;
        case SevenZId.emptyFile:
          info.emptyFile = readBitVector(reader, numEmptyStreams);
        case SevenZId.name:
          final external = reader.readUint8();
          if (external != 0) {
            throw UnsupportedFeatureException(
              'external file names are not supported',
              format: '7z',
            );
          }
          info.names = _readNames(reader, end, numFiles);
        case SevenZId.mTime:
          info.mTimes = _readTimes(reader, numFiles);
        case SevenZId.winAttributes:
          final defined = readAllOrBits(reader, numFiles);
          final external = reader.readUint8();
          if (external != 0) {
            throw UnsupportedFeatureException(
              'external attributes are not supported',
              format: '7z',
            );
          }
          info.attributes = [
            for (var i = 0; i < numFiles; i++)
              defined[i] ? reader.readUint32le() : null,
          ];
        default:
          reader.skip(size); // cTime/aTime/anti/dummy/…: not exposed
      }
      if (reader.position != end) reader.position = end;
    }
    return info;
  }

  static List<String> _readNames(ByteReader reader, int end, int numFiles) {
    final names = <String>[];
    final units = <int>[];
    while (names.length < numFiles && reader.position + 2 <= end) {
      final unit = reader.readUint16le();
      if (unit == 0) {
        names.add(String.fromCharCodes(units));
        units.clear();
      } else {
        units.add(unit);
      }
    }
    if (names.length != numFiles) {
      throw InvalidHeaderException(
        'file name table has ${names.length} names for $numFiles files',
        format: '7z',
      );
    }
    return names;
  }

  static List<DateTime?> _readTimes(ByteReader reader, int numFiles) {
    final defined = readAllOrBits(reader, numFiles);
    final external = reader.readUint8();
    if (external != 0) {
      throw UnsupportedFeatureException(
        'external timestamps are not supported',
        format: '7z',
      );
    }
    return [
      for (var i = 0; i < numFiles; i++) defined[i] ? _fileTime(reader) : null,
    ];
  }

  /// Windows FILETIME (100 ns since 1601) → UTC DateTime, millisecond
  /// precision. Exact integer arithmetic that stays below 2^53 on every
  /// platform: 2^32 = 10000·429496 + 7296.
  static DateTime? _fileTime(ByteReader reader) {
    final lo = reader.readUint32le();
    final hi = reader.readUint32le();
    final msSince1601 = hi * 429496 + (hi * 7296 + lo) ~/ 10000;
    final msSinceEpoch = msSince1601 - 11644473600000;
    if (msSinceEpoch < -62135596800000 || msSinceEpoch > 253402300799000) {
      return null; // out of sane range: best-effort metadata (§7)
    }
    return DateTime.fromMillisecondsSinceEpoch(msSinceEpoch, isUtc: true);
  }
}
