@TestOn('vm')
@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

/// Corpus-driven fuzz smoke (§11): bit-flip and truncation mutations over
/// the committed fixtures. Invariant (§7): any input either parses or
/// throws a typed [ArchiveException] — never a RangeError, never another
/// error type, never a hang, never unbounded memory.
void main() {
  test(
    'mutated fixtures parse or throw typed errors only',
    () async {
      final budget = Duration(
        seconds:
            int.tryParse(
              Platform.environment['KONI_ARCHIVE_FUZZ_SECONDS'] ?? '',
            ) ??
            5,
      );
      final seed = DateTime.now().millisecondsSinceEpoch;
      final random = Random(seed);
      printOnFailure('fuzz seed: $seed');

      final fixtures =
          Directory('test/fixtures/rar')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.rar') || f.path.endsWith('.cbr'))
              .map((f) => f.readAsBytesSync())
              .toList();
      expect(fixtures, isNotEmpty);

      final deadline = DateTime.now().add(budget);
      var iterations = 0;
      while (DateTime.now().isBefore(deadline)) {
        iterations++;
        final base = fixtures[random.nextInt(fixtures.length)];
        final mutated = _mutate(base, random);
        try {
          final reader = await const RarFormat().openReader(
            MemoryByteSource(mutated),
            const ArchiveReadOptions(),
          );
          for (final entry in reader.entries) {
            try {
              var total = 0;
              await for (final chunk in reader.openRead(entry)) {
                total += chunk.length;
                if (total > 1024 * mutated.length + (1 << 20)) {
                  fail(
                    'entry ${entry.path} streamed more bytes than plausible',
                  );
                }
              }
            } on ArchiveException {
              // typed: fine
            }
          }
          await reader.close();
        } on ArchiveException {
          // typed: fine
        }
      }
      printOnFailure('completed $iterations iterations');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Uint8List _mutate(Uint8List base, Random random) {
  var bytes = Uint8List.fromList(base);
  switch (random.nextInt(3)) {
    case 0:
      final flips = 1 + random.nextInt(16);
      for (var i = 0; i < flips; i++) {
        final at = random.nextInt(bytes.length);
        bytes[at] = bytes[at] ^ (1 << random.nextInt(8));
      }
    case 1:
      bytes = Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length));
    case 2:
      if (bytes.length > 1) {
        bytes = Uint8List.fromList(
          Uint8List.sublistView(bytes, 0, 1 + random.nextInt(bytes.length - 1)),
        );
        final flips = 1 + random.nextInt(8);
        for (var i = 0; i < flips && bytes.isNotEmpty; i++) {
          final at = random.nextInt(bytes.length);
          bytes[at] = bytes[at] ^ (1 << random.nextInt(8));
        }
      }
  }
  return bytes;
}
