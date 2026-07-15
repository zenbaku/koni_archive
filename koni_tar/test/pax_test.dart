import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/src/pax.dart';
import 'package:test/test.dart';

import 'src/tar_builder.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('parsePaxRecords', () {
    test('parses records incl. unicode values', () {
      final records = parsePaxRecords(
        _bytes(paxRecord('path', '日本語/ページ001.txt') + paxRecord('size', '1234')),
        0,
      );
      expect(records, {'path': '日本語/ページ001.txt', 'size': '1234'});
    });

    test('later records override earlier ones', () {
      final records = parsePaxRecords(
        _bytes(paxRecord('path', 'first') + paxRecord('path', 'second')),
        0,
      );
      expect(records['path'], 'second');
    });

    test('tolerates trailing NUL padding', () {
      final data = Uint8List(512);
      final record = utf8.encode(paxRecord('path', 'x'));
      data.setRange(0, record.length, record);
      expect(parsePaxRecords(data, 0), {'path': 'x'});
    });

    test('rejects malformed records with typed errors', () {
      for (final bad in [
        'notdigits path=x\n',
        '999 path=x\n', // length beyond data
        '9 pathx==\n'.substring(0, 9), // truncated
        '11 pathnoeq\n',
      ]) {
        expect(
          () => parsePaxRecords(_bytes(bad), 0),
          throwsA(isA<InvalidHeaderException>()),
          reason: bad,
        );
      }
    });

    test('empty data yields no records', () {
      expect(parsePaxRecords(Uint8List(0), 0), isEmpty);
    });
  });

  group('parsePaxTime', () {
    test('parses whole and fractional seconds to UTC', () {
      expect(parsePaxTime('1577934245'), DateTime.utc(2020, 1, 2, 3, 4, 5));
      expect(
        parsePaxTime('1577934245.25'),
        DateTime.utc(2020, 1, 2, 3, 4, 5, 250),
      );
      expect(
        parsePaxTime('1577934245.123456789'), // truncates to micros
        DateTime.utc(2020, 1, 2, 3, 4, 5, 123, 456),
      );
    });

    test('parses negative (pre-epoch) times', () {
      expect(parsePaxTime('-1'), DateTime.utc(1969, 12, 31, 23, 59, 59));
      expect(
        parsePaxTime('-1.25'),
        DateTime.utc(1969, 12, 31, 23, 59, 58, 750),
      );
    });

    test('returns null for garbage or out-of-range (never throws)', () {
      expect(parsePaxTime('not a time'), isNull);
      expect(parsePaxTime(''), isNull);
      expect(parsePaxTime('99999999999999999999'), isNull);
      expect(parsePaxTime('1e10'), isNull);
    });
  });
}
