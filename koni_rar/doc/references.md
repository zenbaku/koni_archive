# koni_rar — reference materials (per §13.7 and doc/rar-provenance.md)

Every reference consulted for the RAR implementation, recorded at first
use. **No unrar source and no GPL/LGPL source was consulted.**

| Reference | License / status | Used for |
| --- | --- | --- |
| libarchive `archive_read_support_format_rar5.c` (Grzegorz Antoniak, 2018) | BSD-2-Clause (notice retained in `NOTICE`) | RAR5 block/header layout, compressed-block bitstream structure, Huffman table encoding, filter semantics — consulted and adapted |
| rarfile project documentation (`rarfile.readthedocs.io`) — format notes | MIT-licensed project docs | RAR5 container field layout cross-check |
| `rar`/`unrar` binaries (RARLAB) | proprietary tools, used as black boxes | fixture generation and behavioral ground truth (§13.3) — never their source |
