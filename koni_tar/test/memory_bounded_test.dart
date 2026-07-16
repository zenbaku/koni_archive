@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/koni_tar.dart';
import 'package:test/test.dart';

import 'src/tar_builder.dart';

/// A [ByteSource] that synthesizes a multi-GiB tar on the fly (no disk, no
/// resident buffer) so the streaming-memory guarantee can be checked
/// against an entry far larger than RAM would forgive.
final class _SyntheticHugeTar implements ByteSource {
  _SyntheticHugeTar(this.entrySize)
    : _header = tarHeader(name: 'huge.bin', size: entrySize);

  final int entrySize;
  final Uint8List _header;

  @override
  String? get name => null;

  @override
  int get length => 512 + _paddedSize + 1024;

  int get _paddedSize => (entrySize + 511) ~/ 512 * 512;

  @override
  Future<Uint8List> read(int offset, int length) {
    final result = Uint8List(length);
    for (var i = 0; i < length; i++) {
      final at = offset + i;
      if (at < 512) {
        result[i] = _header[at];
      } else if (at < 512 + entrySize) {
        result[i] = (at - 512) & 0xFF; // deterministic content
      } // else: padding / end blocks stay zero
    }
    return Future.value(result);
  }

  @override
  Future<void> close() => Future.value();
}

void main() {
  test(
    'streaming a 2 GiB entry keeps memory bounded',
    () async {
      const entrySize = 2 * 1024 * 1024 * 1024; // 2 GiB
      final reader = await const TarFormat().openReader(
        _SyntheticHugeTar(entrySize),
        const ArchiveReadOptions(),
      );
      final entry = reader.entries.single;
      expect(entry.uncompressedSize, entrySize);

      final rssBefore = ProcessInfo.currentRss;
      var maxRss = rssBefore;
      var total = 0;
      var first = true;
      await for (final chunk in reader.openRead(entry)) {
        if (first) {
          // Content sanity: matches the synthetic pattern.
          expect(chunk[0], 0);
          expect(chunk[255], 255);
          first = false;
        }
        total += chunk.length;
        if (total % (256 * 1024 * 1024) < chunk.length) {
          final rss = ProcessInfo.currentRss;
          if (rss > maxRss) maxRss = rss;
        }
      }
      expect(total, entrySize);

      final growth = maxRss - rssBefore;
      // A 2 GiB entry through 64 KiB chunks must not grow the heap by more
      // than a generous slack (GC jitter, test harness noise).
      expect(
        growth,
        lessThan(256 * 1024 * 1024),
        reason: 'peak RSS grew by $growth bytes while streaming 2 GiB',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
