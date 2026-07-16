# Conformance manifests

Committed, per-archive reference manifests for the owner-provided real-world
corpus. The corpus itself is copyrighted and **never
committed**; only these manifests are. They are generated on the owner's
machine by `tool/generate_conformance_manifests.dart` using *reference tools*
(unzip, tar, 7zz, unrar), never koni_archive itself, so they are independent
ground truth.

The conformance runner (`../conformance_test.dart`) reads the corpus location
from the `KONI_ARCHIVE_CORPUS_DIR` environment variable, decodes each archive
with koni_archive, and checks the result against the manifest of the same
name. It skips (marked, not silently) when the corpus is absent.

Manifests land per format milestone, once the runner can decode that format
(all five formats are covered as of M10).

## Schema (v1)

One JSON file per archive, named after the sanitized archive basename:

```json
{
  "schema": 1,
  "archive": {
    "fileName": "<original basename>",
    "sizeBytes": 123456,
    "sha256": "<hex sha-256 of the archive file itself>",
    "format": "zip | tar | gzip | sevenz | rar"
  },
  "tool": { "name": "<reference tool>", "version": "<tool version line>" },
  "entries": [
    {
      "path": "<entry path as stored>",
      "sizeBytes": 123,
      "crc32": "<hex, when the format records one>",
      "sha256": "<hex sha-256 of the decoded entry contents>"
    }
  ]
}
```
