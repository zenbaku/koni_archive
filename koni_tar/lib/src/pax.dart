import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

/// Parses the content of a PAX extended header (`x`/`g` entry) into a
/// key→value map.
///
/// Format (POSIX.1-2001): a sequence of records, each
/// `"%d %s=%s\n" <length> <keyword> <value>`, where `<length>` is the
/// decimal byte length of the *whole* record including the length digits,
/// the space, the `=`, and the trailing newline. Values are UTF-8.
Map<String, String> parsePaxRecords(Uint8List data, int archiveOffset) {
  final records = <String, String>{};
  var pos = 0;
  while (pos < data.length) {
    // Trailing NUL padding to the block boundary is legal.
    if (data[pos] == 0) break;

    InvalidHeaderException malformed(String why) => InvalidHeaderException(
      'malformed PAX record ($why)',
      format: 'tar',
      offset: archiveOffset + pos,
    );

    // Decimal length prefix.
    var length = 0;
    var cursor = pos;
    while (cursor < data.length && data[cursor] != 0x20 /* space */ ) {
      final byte = data[cursor];
      if (byte < 0x30 || byte > 0x39) throw malformed('bad length digit');
      length = length * 10 + (byte - 0x30);
      if (length > data.length) throw malformed('length exceeds data');
      cursor++;
    }
    if (cursor == pos || cursor >= data.length) {
      throw malformed('missing length');
    }
    cursor++; // the space
    final recordEnd = pos + length;
    if (length == 0 || recordEnd > data.length) {
      throw malformed('length out of range');
    }
    if (data[recordEnd - 1] != 0x0A /* \n */ ) {
      throw malformed('missing trailing newline');
    }

    // keyword=value
    var eq = cursor;
    while (eq < recordEnd - 1 && data[eq] != 0x3D /* = */ ) {
      eq++;
    }
    if (eq == recordEnd - 1) throw malformed('missing "="');
    final keyword = utf8.decode(
      Uint8List.sublistView(data, cursor, eq),
      allowMalformed: true,
    );
    final value = utf8.decode(
      Uint8List.sublistView(data, eq + 1, recordEnd - 1),
      allowMalformed: true,
    );
    // Later records with the same keyword override earlier ones (POSIX).
    records[keyword] = value;
    pos = recordEnd;
  }
  return records;
}

/// Parses a PAX decimal timestamp (`mtime`, possibly fractional, possibly
/// negative) into a UTC [DateTime] with microsecond precision. Returns null
/// for garbage rather than failing the whole entry (timestamps are
/// best-effort metadata).
DateTime? parsePaxTime(String value) {
  final match = RegExp(r'^(-?\d+)(?:\.(\d+))?$').firstMatch(value.trim());
  if (match == null) return null;
  final seconds = int.tryParse(match.group(1)!);
  // Hostile timestamps can exceed DateTime's range; timestamps are
  // best-effort metadata, so out-of-range becomes null (fuzz invariant: no
  // ArgumentError). Bound: years 0001-9999.
  if (seconds == null || seconds < -62135596800 || seconds > 253402300799) {
    return null;
  }
  var micros = 0;
  final frac = match.group(2);
  if (frac != null) {
    micros = int.parse(frac.padRight(6, '0').substring(0, 6));
  }
  // "-1.25" is negative(1.25 s): the fraction deepens the magnitude.
  final total =
      seconds * Duration.microsecondsPerSecond +
      (seconds < 0 ? -micros : micros);
  return DateTime.fromMicrosecondsSinceEpoch(total, isUtc: true);
}
