# Vendored yjson algorithms

This directory contains the minimum source set required to use

yjson_algorithms.JsonSchema with cjpm 1.1.3, which cannot address a module in
a Git repository subdirectory. The vendored source is copied from the yjson
0.1.0 release package at the pinned release commit, and includes two
cjdoc-local allocation patches recorded in vendor-manifest.toml:

- `src/lib_json_schema.cj`: avoid a large `RuneArray` allocation while counting JSON Schema string length.
- `src/lib_json_schema.cj`: reuse pointer targets in the private, detached compiled schema instead of deep-copying the same subtree on every reference resolution. Public schema copies, resource context and per-use work limits remain unchanged.

- Upstream: `https://github.com/lIlIIlIll/yjson`
- Release: [yjson 0.1.0](https://github.com/lIlIIlIll/yjson/releases/tag/0.1.0)
- Source commit: `54b4965dee0f0b96710cbc678ec5ec9a126b055c`
- Package: `packages/yjson_algorithms`
- Version: `0.1.0`
- License: Apache-2.0

Included source digests (SHA-256):

- `src/lib_json_patch.cj`: `82115f63f01807f3e7057518579cea4e058baf51c0e767e93e867a3a9c34a5de`
- `src/lib_json_pointer.cj`: `ac5ffe300745a4123fbf0f6ecfb73aa2fc3743c89945dda4bc56c11d1fadf012`
- `src/lib_json_schema.cj`: `ef7d2f872b8ed1557d10ae9e4f5a60931138ab2cef8002795892e7b694ea1091`
- `src/linear_regex.cj`: `21a233eb8915bf9b78f4881093e30e007626e23c8be59bcac7282cf6ad62e3c5`
- `src/work_limits.cj`: `6af3af0f970f47e87ab045ceaf9d9c4675ef7cdc23f27df2870a275b3f057e21`

The inventory is limited to the five production source files needed by cjdoc;
upstream tests, examples, macros, and `lib_json_path.cj` are not vendored.

The adjacent LICENSE is the upstream Apache-2.0 license and governs the
upstream sources and the documented local patches.
