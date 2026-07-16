@TestOn('vm')
@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:koni_rar/src/rar4_filters.dart' show debugForceRar4Vm;
import 'package:test/test.dart';

import 'src/rar4_builder.dart';

/// Corpus-driven fuzz smoke: bit-flip and truncation mutations over
/// the committed fixtures. Invariant: any input either parses or
/// throws a typed [ArchiveException]; never a RangeError, never another
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

      // The generated fixtures (rar/) are all RAR5; the real RAR4 archives,
      // including the encrypted v4 ones, live in rar_static/ (rar 7.x can't
      // author v4, so they are hand-committed there).
      final fixtures = [
        for (final dir in const [
          'test/fixtures/rar',
          'test/fixtures/rar_static',
        ])
          ...Directory(dir)
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.rar') || f.path.endsWith('.cbr'))
              .map((f) => f.readAsBytesSync()),
      ];
      // Also seed a hand-built RAR4 container (store path) into the pool.
      fixtures.add(buildRar4Store({'a.txt': 'hello', 'dir/b.bin': 'x' * 500}));
      fixtures.add(buildRar4Store({'only.txt': 'single stored entry'}));
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

  // Drive the generic RarVM (compile + execute) on corrupt input: mutate the
  // standard-filter fixtures with the force-VM seam on, so the filter programs
  // run through the interpreter. The invariant holds here too, a bad
  // program or region must throw a typed error, never a RangeError or a hang
  // (the VM's memory is masked and its instruction count is capped).
  test(
    'mutated filter fixtures on the generic VM throw typed errors only',
    () async {
      final budget = Duration(
        seconds:
            int.tryParse(
              Platform.environment['KONI_ARCHIVE_FUZZ_SECONDS'] ?? '',
            ) ??
            5,
      );
      final seed = DateTime.now().millisecondsSinceEpoch ^ 0x726d3676;
      final random = Random(seed);
      printOnFailure('fuzz seed: $seed');

      final fixtures = [
        for (final name in const [
          'filter_delta.rar',
          'filter_e8.rar',
          'filter_rgb.rar',
          'filter_audio.rar',
        ])
          File('test/fixtures/rar_static/$name').readAsBytesSync(),
      ];

      debugForceRar4Vm = true;
      try {
        final deadline = DateTime.now().add(budget);
        var iterations = 0;
        while (DateTime.now().isBefore(deadline)) {
          iterations++;
          final mutated = _mutate(
            fixtures[random.nextInt(fixtures.length)],
            random,
          );
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
                    fail('entry ${entry.path} streamed implausibly many bytes');
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
      } finally {
        debugForceRar4Vm = false;
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // The no-password pass above only reaches the "archive is locked" branch for
  // `-hp` archives. Mutating them and opening *with* the password drives the
  // encrypted-header walker itself (per-block salt read, AES decrypt, header
  // size/CRC checks); the same invariant must hold there.
  test(
    'mutated encrypted-header (-hp) archives throw typed errors only',
    () async {
      final budget = Duration(
        seconds:
            int.tryParse(
              Platform.environment['KONI_ARCHIVE_FUZZ_SECONDS'] ?? '',
            ) ??
            5,
      );
      final seed = DateTime.now().millisecondsSinceEpoch ^ 0x48705f34;
      final random = Random(seed);
      printOnFailure('fuzz seed: $seed');

      final fixtures = [
        for (final name in const ['hp_rar4.rar', 'hp_rar4_store.rar'])
          File('test/fixtures/rar_static/$name').readAsBytesSync(),
      ];
      const options = ArchiveReadOptions(password: 'secret');

      final deadline = DateTime.now().add(budget);
      var iterations = 0;
      while (DateTime.now().isBefore(deadline)) {
        iterations++;
        final mutated = _mutate(
          fixtures[random.nextInt(fixtures.length)],
          random,
        );
        try {
          final reader = await const RarFormat().openReader(
            MemoryByteSource(mutated),
            options,
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
