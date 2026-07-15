# Project Prompt: Pure Dart Archive Library

---

## Project Overview

Build a **pure Dart archive library** that supports reading the most common archive formats with a modern, streaming-first API.

The library must run anywhere Dart runs:

* Flutter Android
* Flutter iOS
* Flutter macOS
* Flutter Windows
* Flutter Linux
* Dart VM
* (Eventually) Web, where supported by browser APIs

**No native code.**
**No FFI.**
**No external executables.**

The project should be designed as a long-term ecosystem, not merely an archive parser.

---

# Philosophy

The primary use case is **streaming files from archives**, not extracting them to disk.

Typical consumers include:

* Manga readers (CBZ/CBR/CB7/CBT)
* Ebook readers
* File explorers
* Asset packs
* Games
* Backup tools

A caller should think of an archive as a **virtual filesystem**.

Example:

```dart
final archive = await Archive.open(file);

for (final entry in archive.entries) {
  print(entry.path);
}

final stream = archive.open("chapter01/page001.webp");
```

The caller should not care whether the archive is ZIP, TAR, 7z or RAR.

---

# Goals

## Phase 1

Read archives.

Supported formats (implemented incrementally):

* TAR
* ZIP
* 7z
* RAR

Initially:

* read-only
* no archive creation
* no modification
* no encryption
* no password support

Focus on correctness and streaming.

---

## Phase 2

Archive creation.

Support writing:

* ZIP
* TAR

Eventually:

* 7z

RAR writing is out of scope unless legally feasible.

---

# Design Principles

## 1. Streaming-first

Avoid APIs like

```dart
Uint8List read(...)
```

Prefer

```dart
Stream<List<int>> open(...)
```

or

```dart
Future<ArchiveInputStream> open(...)
```

Large files should never require loading into memory.

---

## 2. Random access when possible

If the archive format allows it, support

```dart
reader.open("image123.jpg")
```

without extracting previous files.

For solid archives, document limitations.

---

## 3. Lazy parsing

Opening an archive should be inexpensive.

Metadata should be parsed eagerly.

Compressed contents should be decoded only when requested.

---

## 4. Format-independent API

Consumers should never need

```dart
ZipReader(...)
```

Instead:

```dart
final archive = await Archive.open(file);
```

Automatic format detection.

---

## 5. Immutable

Archive entries should be immutable.

Readers should expose read-only state.

---

## Package Structure

```text
archive_plus/
    archive_plus.dart

archive_core/
archive_zip/
archive_tar/
archive_7z/
archive_rar/

archive_codecs/
```

Alternatively

```text
archive/
archive_core/
archive_codecs/
```

is acceptable.

---

# archive_core

This package contains reusable infrastructure.

Examples:

* ByteReader
* BitReader
* RandomAccessReader
* BufferedReader
* StreamReader
* CRC32
* Adler32
* Huffman decoder
* Range decoder
* Sliding window
* LZ dictionary
* Utility classes
* ArchiveEntry
* ArchiveReader
* ArchiveFormat enum

No archive-specific code belongs here.

---

# archive_codecs

Compression algorithms.

Examples

* Deflate
* Inflate
* LZMA
* LZMA2
* BZip2
* XZ
* Delta filters
* BCJ filters

These should be reusable outside archive formats.

---

# Public API

Example:

```dart
final archive = await Archive.open(file);

archive.entries

archive.files

archive.directories

archive.contains("page001.webp")

archive.open("page001.webp")

archive.read("page001.webp")

archive.close()
```

---

## ArchiveEntry

```dart
class ArchiveEntry {

  String path;

  bool isDirectory;

  int compressedSize;

  int uncompressedSize;

  DateTime? modified;

  bool isCompressed;

  ArchiveCompression compression;

}
```

---

# Detection

Support automatic detection via signatures.

Examples:

ZIP

```
50 4B 03 04
```

RAR

```
52 61 72 21
```

7z

```
37 7A BC AF 27 1C
```

TAR

```
ustar
```

The caller should never specify the format manually.

---

# Streaming API

Preferred API:

```dart
final stream = archive.open(path);

await stream.pipe(...);
```

Possible helper:

```dart
final bytes = await archive.read(path);
```

implemented internally by collecting the stream.

Streaming is the primary API.

---

# Virtual Filesystem

The archive should behave similarly to a filesystem.

Desired operations:

```dart
archive.entries

archive.file(path)

archive.exists(path)

archive.open(path)

archive.walk()

archive.glob("**/*.png")
```

Future support:

```dart
archive["images/a.png"]
```

---

# Error Handling

Provide typed exceptions.

Examples:

```dart
ArchiveException

UnsupportedFormatException

CorruptArchiveException

UnexpectedEOFException

UnsupportedCompressionException

InvalidHeaderException
```

Avoid generic exceptions.

---

# Performance

Priorities:

* minimal allocations
* streaming
* lazy decoding
* support archives containing tens of thousands of files

Avoid copying buffers unnecessarily.

---

# Testing

Every parser should have:

* valid archives
* corrupted archives
* truncated archives
* malformed headers
* zero-length files
* empty archives
* nested directories
* Unicode filenames
* very long filenames
* large files

Property-based tests are encouraged.

---

# Documentation

Every format should include:

* architecture overview
* references
* supported features
* unsupported features
* implementation notes

Explain why certain tradeoffs were made.

---

# Roadmap

## Milestone 1

Core infrastructure

* Byte readers
* Streams
* CRC
* Exceptions
* Archive abstraction

---

## Milestone 2

TAR

Reason:

* simplest format
* validates architecture
* no compression

---

## Milestone 3

ZIP

Support:

* Deflate
* Stored
* Directories
* ZIP64 later

---

## Milestone 4

GZIP

---

## Milestone 5

TAR.GZ

---

## Milestone 6

7z

Implement container first.

Then codecs.

---

## Milestone 7

RAR

Implement after architecture has matured.

---

# Non-goals (initially)

* Encryption
* Password-protected archives
* Self-extracting executables
* Multi-volume archives
* Archive repair
* Legacy obscure compression methods

These can be added later.

---

# Code Quality Expectations

* Idiomatic Dart 3
* Strongly typed
* Null-safe
* Thoroughly documented
* Comprehensive unit tests
* Separation of parsing, container logic, and compression codecs
* Avoid premature optimization, but design with extensibility in mind

---

# Long-Term Vision

The goal is not simply to create "another ZIP library." The goal is to build the **canonical archive ecosystem for Dart**, analogous to foundational archive libraries in other ecosystems.

The architecture should:

* Treat archives as **virtual filesystems**.
* Be **streaming-first** for efficient media consumption (e.g., comic and ebook readers).
* Share reusable infrastructure (bit readers, codecs, checksums, etc.) across formats.
* Make adding future formats (XZ, CPIO, AR, CAB, ISO, WIM, etc.) straightforward.
* Allow compression codecs to be reused independently of archive containers.
* Eventually support both reading and writing while maintaining a consistent, format-agnostic API.

A developer should be able to write application code without knowing—or caring—which archive format is being used. The library should provide a unified abstraction that is performant, predictable, and portable across the entire Dart ecosystem.
