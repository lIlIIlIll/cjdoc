# Third-party notices

The cjdoc executable statically incorporates the following pinned dependencies.
Their license texts are distributed with every binary archive.

## markdown 0.9.0

- Upstream: <https://github.com/lIlIIlIll/markdown>
- Commit: `db4f9527944b589db8436669f1d255192388cee2`
- License: MIT
- Repository license text: `third_party/licenses/markdown-LICENSE`
- Binary-archive license text: `licenses/markdown-MIT.txt`

## yjson 2.0.1

- Upstream: <https://github.com/lIlIIlIll/yjson>
- Commit: `bf65cbecd99ac25e7485f8db60990e94a04e57bc`
- License: Apache-2.0
- Repository license text: `vendor/yjson_algorithms/LICENSE`
- Binary-archive license text: `licenses/yjson-Apache-2.0.txt`

## yjson_algorithms 2.0.1

The four `.cj` source files under `vendor/yjson_algorithms/src` are copied from
`packages/yjson_algorithms` at the same yjson commit listed above, with one
cjdoc-local memory-safety patch in `src/lib_json_schema.cj` that counts JSON
Schema string length without materializing a large `RuneArray`. The adjacent
`cjpm.toml` is a cjdoc-local package manifest that pins yjson at that commit.
The exact source inventory, local patch declaration, and adapted manifest are
bound by `vendor/yjson_algorithms/vendor-manifest.toml`.

- License: Apache-2.0
- Repository license text: `vendor/yjson_algorithms/LICENSE`
- Binary-archive license text: `licenses/yjson-Apache-2.0.txt`
