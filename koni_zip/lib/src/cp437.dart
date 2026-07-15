import 'dart:convert';
import 'dart:typed_data';

/// Code page 437 (original IBM PC) high half, indices 128–255, per the
/// standard CP437→Unicode mapping (last char is U+00A0 NBSP).
const String _cp437High =
    'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»'
    '░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀'
    'αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ';

/// Decodes a ZIP name/comment field (§8). Never throws (§7).
///
/// With the UTF-8 flag (general-purpose bit 11) set, the bytes are UTF-8 by
/// declaration: decoded permissively (invalid sequences become U+FFFD —
/// mojibake beats an unreadable archive). With the flag unset, the bytes
/// are nominally CP437, but many tools wrote UTF-8 anyway: strict UTF-8 is
/// attempted first and CP437 is the fallback. A caller-supplied decoder
/// hook lands in the hardening milestone (M7).
String decodeZipString(Uint8List bytes, {required bool utf8Flagged}) {
  if (utf8Flagged) return utf8.decode(bytes, allowMalformed: true);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.writeCharCode(
        byte < 128 ? byte : _cp437High.codeUnitAt(byte - 128),
      );
    }
    return buffer.toString();
  }
}
