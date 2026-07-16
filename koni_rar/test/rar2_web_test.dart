// Web-runnable RAR 2.0 (unpack version 20) decoding (R9). Real v20 fixtures,
// authored with DOS RAR 2.50 under DOSBox (no modern tool writes v20), inlined
// as base64 so the shared bit-reader/Huffman and the v20 LZ path run on dart2js
// and dart2wasm, not just the VM. Reading verifies CRC-32 by default, so a
// decode that completes is byte-exact (also checked vs unrar locally). The same
// archives live in test/fixtures/rar_static/ for the fuzz smoke test.
//
// Regenerate: DOS RAR 2.50 (rarlab rar250.exe) under DOSBox:
//   rar a -m3 rar2_lz_repeat.rar REPEAT.TXT
//   rar a -m5 -mm rar2_audio.rar AUDS.RAW   (multimedia/audio block)
// See doc/notes.md ("RAR 2.0 / 2.6").
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

// DOS RAR 2.50 -m3 over 128200 bytes of a repeated 16-byte pattern; LZ block
// (literals then matches). Trips the v20 main/offset/length Huffman and the
// short-offset and reused-offset paths.
final _lzRepeat = base64.decode(
  'UmFyIRoHAM+QcwAADQAAAAAAAABKnnQAgCoA9AEAAMj0AQAAJ3Vxi0IP8FwUMwoAIAAAAFJFUEVB'
  'VC5UWFQMzRQVVMAAABDOf9Vvff7d/01nSvSukOSKUhVIoMAwH4fH5fP6fX7ff8fn9fv+e/9/3eve'
  'bPbvCB/vcAfPd4Qn54+e7whPzx893hCfnj57vCE/PHz3eEJ+ePnj+nj54/p4+eP6ePnj+nj54/p4'
  '+eP6ePnj+nj54/p4+eP6ePnj+nj54/p4+eP6ePnj+nj54/p4+eP6ePnj+nj54/p4+eP6ePnj+nj5'
  '4/vI+nj54+e7whPzx893hCfnj57vCE/PHz3eEJ+ePnu8IT88fPH9PHzx/Tx88f08fPH9PHzx/Tx8'
  '8f08fPH9PHzx/Tx88f08fPH9PHzx/Tx88f08fPH9PHzx/Tx88f08fPH9PHzx/Tx88f08fPH9PHzx'
  '/eS9PHzx893hCfnj57vCE/PHz3eEJ+ePnu8IT88fPd4Qn54+eP6ePnj+nj54/p4+eP6ePnj+nj54'
  '/p4+eP6ePnj+nj54/p4+eP6ePnj+nj54/p4+eP6ePnj+nj54/p4+eP6ePnj+nj54/p4+eP6ePnj+'
  '8l6ePnj57vCE/PHz3eEJ+ePnu8IT88fPd4Qn54+e7whPzx88f08fPH9PHzx/Tx88f08fPH9PHzx/'
  'Tx88f08fPH9PHzx/Tx88f08fPH9PHzx/Tx88f08fPH9PHzx/Tx88f08fPH9PH/Pr2A==',
);

// DOS RAR 2.50 -m5 -mm over 3000 bytes of 16-bit PCM, a multimedia/audio
// block. The RAR 2.x audio predictor has no correct permissive reference
// (rardecode's mis-decodes it, verified vs unrar), so it is a typed error.
final _audio = base64.decode(
  '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'
  'hW7WIZgRGF+kQnAhzm5EBSvFI2A=',
);

Future<ArchiveReader> _open(Uint8List bytes) => const RarFormat().openReader(
  MemoryByteSource(bytes),
  const ArchiveReadOptions(),
);

void main() {
  test('RAR 2.0 LZ block decodes (CRC-verified) on this platform', () async {
    final reader = await _open(_lzRepeat);
    final entry = reader.entries.single;
    final chunks = await reader.openRead(entry).toList();
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    expect(total, 128200);
    expect(chunks.first.first, 'A'.codeUnitAt(0));
    await reader.close();
  });

  test(
    'RAR 2.0 multimedia/audio block is a typed error on this platform',
    () async {
      final reader = await _open(_audio);
      await expectLater(
        reader.openRead(reader.entries.single).toList(),
        throwsA(isA<UnsupportedFeatureException>()),
      );
      await reader.close();
    },
  );
}
