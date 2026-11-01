# Upstream

| item | value |
|---|---|
| package | `camera_android_camerax` |
| version | `0.7.4+8` (the version the app pins in `pubspec.yaml`) |
| archive | `https://pub.dev/api/archives/camera_android_camerax-0.7.4%2B8.tar.gz` |
| archive sha256 | `977f54512d338b3b36d7f82929794886766d8f41ae84a48fe103eb0106ecfe25` |
| repository | `https://github.com/flutter/packages/tree/main/packages/camera/camera_android_camerax` |
| license | BSD-3-Clause, `LICENSE` here and in `package/` |

The reference for the hash is the pub.dev API, not this repository's history: field
`archive_sha256` of `https://pub.dev/api/packages/camera_android_camerax/versions/0.7.4%2B8`.

`package/` = the archive, without `example/`, plus `patches/`:

| patch | sha256 |
|---|---|
| `0001-drop-VideoRecordEvent-Status-before-Pigeon.patch` | `9852fa3975a8a6be1885951fb4a525a00c2a85c05a26df807aa2cfab077a520e` |
| `0002-status-filter-tests.patch` | `42375e31b40c22d9ba295972402ecf313a30773b5c9e0376a9715b537e833ac1` |

`verify.sh` checks all of this byte for byte. See [README.md](README.md).
