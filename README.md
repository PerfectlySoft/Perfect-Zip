# Perfect Zip

<p align="center">
    <img src="https://img.shields.io/badge/Swift-6.2%2B-orange.svg?style=flat" alt="Swift 6.2+">
    <img src="https://img.shields.io/badge/Platforms-macOS%2012%2B%20%7C%20Linux-lightgray.svg?style=flat" alt="Platforms macOS 12+ | Linux">
    <a href="LICENSE" target="_blank"><img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache"></a>
</p>

Create a zip archive from files and directories, or extract one into a directory, safely.

The ZIP format is implemented in Swift. Compression uses the system zlib (raw deflate and
inflate, and CRC-32), which ships with macOS and is `zlib1g-dev` on Debian and Ubuntu. There
are no other dependencies and no bundled C code.

## Installation

```swift
.package(url: "https://github.com/PerfectlySoft/Perfect-Zip.git", from: "4.0.0"),
```

and add `.product(name: "PerfectZip", package: "Perfect-Zip")` to your target.

**Requirements:** Swift 6.2 or later (Swift 6 language mode), macOS 12 or later, or Linux
with the zlib headers (`apt-get install zlib1g-dev`; the official `swift` Docker images
already have them).

## Usage

```swift
import PerfectZip

let zip = Zip()

// Archive a directory (recursively) and a file. Each becomes a top-level entry.
let status = zip.zipFiles(paths: ["/path/to/photos", "/path/to/notes.txt"],
                          zipFilePath: "/path/to/out.zip",
                          overwrite: true)
guard status == .ZipSuccess else { fatalError(status.description) }

// Extract it.
let result = zip.unzipFile(source: "/path/to/out.zip",
                           destination: "/path/to/extracted",
                           overwrite: true)
print(result.description) // "Success."
```

Both calls are synchronous and return a `ZipStatus`; `.ZipSuccess` is the only success value.
`Zip` is `Sendable` and stateless apart from its limits, so one instance can be shared.

**Reading encrypted archives.** Archives encrypted with traditional PKWARE encryption
(`zip -P`, "ZipCrypto") can be read:

```swift
let status = Zip().unzipFile(source: "secret.zip", destination: "out", overwrite: true,
                             password: "hunter2")
// .UnzipIncorrectPassword if the password is missing or wrong; nothing is written then.
```

AES-encrypted entries (WinZip AE-1/AE-2) are not supported, and PerfectZip does not create
encrypted archives (ZipCrypto is broken; see Security).

**Zip-bomb limits.** Extraction refuses archives that would expand beyond `ZipLimits`, with
`.UnzipLimitExceeded`, before writing anything:

```swift
// Defaults: at most 16 GiB in total, and at most 200:1 (declared uncompressed size divided
// by compressed size, integer division) for every entry of 1 MiB or more, and for all the
// entries that will be extracted together once they add up to 1 MiB or more (skipped
// __MACOSX/ entries are left out of that sum, so padding there can't dilute it).
let strict = Zip(limits: ZipLimits(maxTotalUncompressedSize: 100 << 20, maxCompressionRatio: 100))
let trusted = Zip(limits: .unlimited) // only for archives you trust
```

## What gets written and restored

- **Entries:** directories are walked recursively and stored with their own entries, so
  empty directories survive. Names are UTF-8 (with the UTF-8 flag set when non-ASCII). Files
  over about 4 GB, offsets past 4 GB and 65,535 or more entries use Zip64.
- **Symbolic links:** a path you pass in `paths` is followed if it is a link. Links found while
  walking a directory are skipped, so they can't loop or pull in files from outside the tree.
  Extraction never creates links: a symlink entry in an archive becomes a regular file holding
  the link text.
- **Permissions and times:** Unix permission bits and modification times are recorded (DOS
  time plus the UTC "UT" extra field) and restored on extraction. Setuid, setgid and sticky
  bits are never restored. Directories are created with mode 0o755 (less your umask) and get
  no times: restoring a directory's mode could lock extraction out of it (a read-only or
  non-searchable directory), and its time would change again as its entries are written.
- **Replacing files** (`overwrite: true`): the old file is replaced, even if it is read-only.
  It keeps its permission bits when the archive has none (archives made on Windows); its
  ownership, ACLs and extended attributes are not kept.
- **Skipped:** `.DS_Store` files and `__MACOSX` directories when zipping, and `__MACOSX/`
  entries when unzipping.
- **Atomic output:** `zipFiles` writes to a temporary file next to `zipFilePath` and renames it
  into place, so a failure never leaves a half-written archive or destroys the one it replaces.

## Status codes

| Status | Meaning |
|---|---|
| `ZipSuccess` | Done. |
| `FileNotFound` | `source` or one of `paths` doesn't exist. |
| `ZipCannotOverwrite` | `overwrite: false` and the destination (or the archive file) exists, or an archive names the same file twice. |
| `ZipFail` | Creating the archive failed: bad name (`zipFilePath` must end in `.zip`), I/O error, or two entries with the same name. |
| `UnzipFail` | The archive is damaged or unsupported (method, multi-disk, AES, data before the archive), or an I/O error. |
| `UnzipUnsafePath` | An entry name is unsafe or more than 256 components deep, or extraction would go through a symbolic link. New in 4.0. |
| `UnzipLimitExceeded` | The archive exceeds `ZipLimits`. New in 4.0. |
| `UnzipIncorrectPassword` | An entry is encrypted and the password is missing or wrong. New in 4.0. |
| `ZipEncryptionUnsupported` | A password was passed to the deprecated `zipFiles(...password:)`. New in 4.0. |

## Security

Extraction is designed for untrusted archives.

- **Path validation (Zip Slip).** Before anything is written, every entry name is checked. A
  name that is absolute (`/etc/x`, `C:\x`), contains a `..` component (with `/` or `\`
  separators), contains NUL, or would resolve outside the destination fails the whole
  extraction with `UnzipUnsafePath`, and nothing is extracted. The destination itself may be
  reached through a symlink; it is resolved first.
- **No writes through symlinks.** Files are created relative to a descriptor for the resolved
  destination with `O_NOFOLLOW` at every level, so a symlink already inside the destination is
  never followed or replaced; meeting one fails with
  `UnzipUnsafePath`.
- **No writes through hard links.** With `overwrite: true`, an existing file is never
  truncated or written in place. The entry is written to a temporary file in the same
  directory and renamed over the original only after it is complete and its CRC has checked
  out. A hard link inside the destination that shares its inode with a file elsewhere is
  broken rather than written through, and a failed replacement leaves the original intact.
- **Depth.** Entry names may have at most 256 path components; deeper ones fail with
  `UnzipUnsafePath`. Each entry opens its directories from the destination root again, which
  the cap keeps bounded.
- **Concurrent changes.** These guarantees are against hostile archives. If another process
  changes the destination while extraction runs (renaming a directory out of it, say), the
  entry being written at that moment can end up wherever that directory went; every later
  entry is placed from the destination root again, and a symlink swapped in is refused.
- **Structure.** Every length and offset is bounds-checked with overflow-safe arithmetic; each
  local header must match its central-directory record; overlapping entries are refused; an
  entry may not produce more data than it declares, and its CRC is verified.
- **Zip bombs.** `ZipLimits` caps the total size, and the compression ratio both per entry
  and over all extracted entries together (so splitting a bomb into many small entries, or
  padding it with never-written `__MACOSX/` data, doesn't help),
  checked against the declared sizes before extraction starts. Each entry must then produce
  exactly its declared size.
- **Failure.** Structural, name, limit and password problems are found before anything is
  written. Some problems only show up during extraction: a damaged deflate stream, a full
  disk, a symlink inside the destination, a file where the destination has a directory, or
  two names that the filesystem treats as one (such as a case-only difference on a
  case-insensitive volume). These fail closed and leave a partial result: entries already
  extracted stay, the failing file is removed, and a file it would have replaced is kept.
- **Passwords.** ZipCrypto is cryptographically broken; it is supported for reading old
  archives only. Don't rely on it for secrecy.

The reader has been fuzzed (libFuzzer on Linux, and mutated archives under AddressSanitizer)
and is tested against archives from Info-ZIP `zip`, macOS `ditto`, `bsdtar` and Python's
`zipfile`. The harness is in [`Fuzz/`](Fuzz/Package.swift).

## Migrating from 3.x

- **Install line:** `from: "4.0.0"`. Swift 6.2 is the minimum.
- **No `minizip` module.** The bundled C library and its `minizip` product are gone. If you
  imported `minizip` directly, use another zip library for that code.
- **Passwords on `zipFiles` are gone.** `zipFiles(paths:zipFilePath:overwrite:password:)` is
  deprecated; with a non-empty password it returns `ZipEncryptionUnsupported` and writes
  nothing. Call `zipFiles(paths:zipFilePath:overwrite:)`. (In 3.x, encrypted archives had a wrong
  check byte, so `unzip`, Python and other tools rejected their password, and 3.x's own
  `unzipFile` ignored its `password` argument, so encryption never worked end to end.)
- **New `ZipStatus` cases:** `UnzipUnsafePath`, `UnzipLimitExceeded`, `UnzipIncorrectPassword`
  and `ZipEncryptionUnsupported`. An exhaustive `switch` needs them (or `default:`).
- **Stricter extraction.** Archives that 3.x extracted "successfully" may now fail: unsafe
  names, symlinks in the destination, damaged archives (3.x often reported success with files
  missing), archives over the default limits (pass `Zip(limits:)`), duplicate names with
  `overwrite: false`, and self-extracting archives with data in front.
- **Different output.** Archives now contain directory entries, permissions, real timestamps
  (3.x wrote zeros) and Zip64 where needed; extraction restores permissions and times.
- **`ProcessedFilePath`** is deprecated and unused.

The pre-Swift-6 code is on the [`legacy`](../../tree/legacy) branch.

## Further information

For more information on the Perfect project, please visit [perfect.org](http://perfect.org).
