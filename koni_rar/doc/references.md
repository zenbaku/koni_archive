# koni_rar — reference materials (per §13.7 and doc/rar-provenance.md)

Every reference consulted for the RAR implementation, recorded at first
use. **No unrar source and no GPL/LGPL source was consulted.**

| Reference | License / status | Used for |
| --- | --- | --- |
| libarchive `archive_read_support_format_rar5.c` (Grzegorz Antoniak, 2018) | BSD-2-Clause (notice retained in `NOTICE`) | RAR5 block/header layout, compressed-block bitstream structure, Huffman table encoding, filter semantics — consulted and adapted |
| libarchive `archive_read_support_format_rar.c` (Tim Kientzle 2003–2007, Andres Mejia 2011) | BSD-2-Clause (notice retained in `NOTICE`) | RAR4 (v1.5) block/header layout and the method-29 (v29) LZSS+Huffman unpack (block tables, length/distance decoding, short/long LZ) — consulted and adapted. **RarVM standard filters** (`rar4_filters.dart`): the filter-record reader (`read_filter`/`parse_filter`/`compile_program`), the memory bit-reader + vint (`membr_*`), the fingerprint dispatch, and the delta/E8/E8E9/RGB/audio `execute_filter_*` algorithms — consulted and adapted. PPMd variant H and a *generic* RarVM bytecode interpreter (for non-standard programs) were **not** implemented: the only interpreter reference is GPL unrar, so custom filters stay a typed error. |
| rarfile project documentation (`rarfile.readthedocs.io`) — format notes | MIT-licensed project docs | RAR5 container field layout cross-check; RAR5 encryption record + KDF description (P3-4) |
| Go `rardecode` (`github.com/nwaples/rardecode`, `archive50.go`) | BSD-2-Clause | RAR5 encrypted-header (`-hp`) block framing cross-check: per-block clear IV + AES-256-CBC header padded to 16, block key covers headers only (data uses the per-file record), and the file-record flag split (bit 0 password-check vs bit 1 "use MAC"/CRC-tweak). libarchive's `rar5.c` has **no** crypto, so it could not serve here. |
| RARLAB RAR5 archive format technote (`www.rarlab.com/technote.htm`) | public format documentation | RAR5 encryption record fields, AES-256-CBC, PBKDF2-HMAC-SHA256 key/IV/check derivation (P3-4) |
| RAR3/RAR4 encryption format notes (rarfile docs + published clean-room analyses) | MIT docs / public analyses | RAR4 encryption: SHA-1 KDF (0x40000 rounds), header salt, AES-128-CBC key/IV derivation (P3-5) — verified empirically against rar 6.24 output |
| `rar`/`unrar` binaries (RARLAB) | proprietary tools, used as black boxes | fixture generation and behavioral ground truth (§13.3), incl. empirical verification of the P3-4 KDF/tweaked-CRC against authored fixtures — never their source |
