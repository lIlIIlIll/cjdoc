# Vendored yjson algorithms

This directory contains the minimum source set required to use

yjson_algorithms.JsonSchema with cjpm 1.1.3, which cannot address a module in
a Git repository subdirectory. The vendored source is copied from the yjson
0.1.0 release package at the pinned release commit, and includes one
cjdoc-local memory-safety patch recorded in vendor-manifest.toml:

- `src/lib_json_schema.cj`: avoid a large `RuneArray` allocation while counting JSON Schema string length.

Patch reason: Avoid large RuneArray allocation while counting JSON Schema string length.

- Upstream: `https://github.com/lIlIIlIll/yjson`
- Release: [yjson 0.1.0](https://github.com/lIlIIlIll/yjson/releases/tag/0.1.0)
- Source commit: `54b4965dee0f0b96710cbc678ec5ec9a126b055c`
- Package: `packages/yjson_algorithms`
- Version: `0.1.0`
- License: Apache-2.0

Included source digests (SHA-256):

- `src/lib_json_patch.cj`: `82115f63f01807f3e7057518579cea4e058baf51c0e767e93e867a3a9c34a5de`
- `src/lib_json_pointer.cj`: `ac5ffe300745a4123fbf0f6ecfb73aa2fc3743c89945dda4bc56c11d1fadf012`
- `src/lib_json_schema.cj`: `090446931f6b1838a56c21a56472833d0e926445558d7a2b4fc217c9918ddd94`
- `src/linear_regex.cj`: `21a233eb8915bf9b78f4881093e30e007626e23c8be59bcac7282cf6ad62e3c5`
- `src/work_limits.cj`: `6af3af0f970f47e87ab045ceaf9d9c4675ef7cdc23f27df2870a275b3f057e21`

The inventory is limited to the five production source files needed by cjdoc;
upstream tests, examples, macros, and `lib_json_path.cj` are not vendored.

The adjacent LICENSE is the upstream Apache-2.0 license and governs the
upstream sources and the documented local patch.
