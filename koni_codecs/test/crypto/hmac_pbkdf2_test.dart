import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_codecs/crypto.dart';
import 'package:test/test.dart';

String hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List ascii(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List filled(int length, int byte) =>
    Uint8List.fromList(List.filled(length, byte));

void main() {
  group('HMAC-SHA1 (RFC 2202 vectors)', () {
    test('case 1: 20-byte key', () {
      expect(
        hex(Hmac.sha1(filled(20, 0x0b)).compute(ascii('Hi There'))),
        'b617318655057264e28bc0b6fb378c8ef146be00',
      );
    });

    test('case 2: short key "Jefe"', () {
      expect(
        hex(
          Hmac.sha1(
            ascii('Jefe'),
          ).compute(ascii('what do ya want for nothing?')),
        ),
        'effcdf6ae5eb2fa2d27416d5f184df9c259a7c79',
      );
    });

    test('case 3: 0xaa key, 0xdd data', () {
      expect(
        hex(Hmac.sha1(filled(20, 0xaa)).compute(filled(50, 0xdd))),
        '125d7342b9ac11cd91a39af48aa17b4f63f175d3',
      );
    });

    test('case 6: key longer than the block size', () {
      expect(
        hex(
          Hmac.sha1(filled(80, 0xaa)).compute(
            ascii('Test Using Larger Than Block-Size Key - Hash Key First'),
          ),
        ),
        'aa4ae5e15272d00e95705637ce8a3b55ed402112',
      );
    });

    test('reset() reuses the key for a second message', () {
      final mac = Hmac.sha1(filled(20, 0x0b));
      mac.add(ascii('Hi '));
      mac.add(ascii('There'));
      expect(hex(mac.finish()), 'b617318655057264e28bc0b6fb378c8ef146be00');
      mac.reset();
      mac.add(ascii('Hi There'));
      expect(hex(mac.finish()), 'b617318655057264e28bc0b6fb378c8ef146be00');
    });
  });

  group('HMAC-SHA256 (RFC 4231 vectors)', () {
    test('case 1: 20-byte key', () {
      expect(
        hex(Hmac.sha256(filled(20, 0x0b)).compute(ascii('Hi There'))),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });

    test('case 2: short key "Jefe"', () {
      expect(
        hex(
          Hmac.sha256(
            ascii('Jefe'),
          ).compute(ascii('what do ya want for nothing?')),
        ),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
    });

    test('case 6: 131-byte key (hashed first)', () {
      expect(
        hex(
          Hmac.sha256(filled(131, 0xaa)).compute(
            ascii('Test Using Larger Than Block-Size Key - Hash Key First'),
          ),
        ),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
      );
    });
  });

  group('PBKDF2-HMAC-SHA1 (RFC 6070 vectors)', () {
    test('c=1', () {
      expect(
        hex(pbkdf2(Hmac.sha1(ascii('password')), ascii('salt'), 1, 20)),
        '0c60c80f961f0e71f3a9b524af6012062fe037a6',
      );
    });

    test('c=2', () {
      expect(
        hex(pbkdf2(Hmac.sha1(ascii('password')), ascii('salt'), 2, 20)),
        'ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957',
      );
    });

    test('c=4096', () {
      expect(
        hex(pbkdf2(Hmac.sha1(ascii('password')), ascii('salt'), 4096, 20)),
        '4b007901b765489abead49d926f721d065a429c1',
      );
    });

    test('c=4096, multi-block dkLen=25', () {
      expect(
        hex(
          pbkdf2(
            Hmac.sha1(ascii('passwordPASSWORDpassword')),
            ascii('saltSALTsaltSALTsaltSALTsaltSALTsalt'),
            4096,
            25,
          ),
        ),
        '3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038',
      );
    });

    test('c=4096, embedded NULs', () {
      expect(
        hex(
          pbkdf2(Hmac.sha1(ascii('pass\x00word')), ascii('sa\x00lt'), 4096, 16),
        ),
        '56fa6aa75548099dcc37d7f03425e0c3',
      );
    });
  });

  group('PBKDF2-HMAC-SHA256 (RFC 7914 §11 vectors)', () {
    test('c=1, dkLen=64', () {
      expect(
        hex(pbkdf2(Hmac.sha256(ascii('passwd')), ascii('salt'), 1, 64)),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
    });

    test('c=80000, dkLen=64', () {
      expect(
        hex(pbkdf2(Hmac.sha256(ascii('Password')), ascii('NaCl'), 80000, 64)),
        '4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56'
        'a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d',
      );
    });
  });
}
