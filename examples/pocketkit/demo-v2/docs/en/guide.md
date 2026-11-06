# Catalogue and lifetime

Use the PocketKit **0.2.0** teaching snapshot to store text, retain a snapshot, handle index errors, and close a reading session.
These four exercises are this tutorial's tasks, not a list of the library's core tasks. The programs are verified with **Cangjie STS 1.2.0**.

## Set up the caller project

Install Cangjie STS 1.2.0 and check that `cjc -v` and `cjpm -v` work. Obtain this repository's source,
keeping `examples/pocketkit/demo-v2` and `examples/pocketkit/support-v1` in their relative locations.
A caller needs the SDK and these library sources, but no cjdoc binary, stdx, or documentation-site reproduction.

Create `examples/pocketkit/guide-caller` and save the following as its `cjpm.toml`.
The `pocketkit` static path dependency is relative to this manifest.

```toml
[package]
cjc-version = "1.2.0"
name = "guide_caller"
version = "1.0.0"
output-type = "executable"

[dependencies]
pocketkit = { path = "../demo-v2", output-type = "static" }
```

Create a `src` directory inside the caller project, then save **one complete program** below as `examples/pocketkit/guide-caller/src/main.cj`.
Replace `src/main.cj` separately for each exercise; do not concatenate the four programs.
For each program, use `examples/pocketkit/guide-caller` as the working directory and run:

```sh
cjpm run --build-args "--jobs 1"
```

The build may print status lines first. A successful program must print that section's single `PASS guide-…` marker.
A compilation or assertion failure is not success. These programs are single-threaded: `TextCatalog` and `TextReader`
do not synchronize internally. Concurrent callers must arrange synchronization as described by the API author.

## Store and read text

Create an empty catalogue and append unchanged text with the `String` overload. Indices start at zero.

| Precisely associated API | Use in this task |
| --- | --- |
<!-- cjdoc-bind target="pocketkit.TextCatalog.init" selector="signature:public init()" provenance="docs/en/guide.md" version="demo-v2" -->
| `TextCatalog()` | Create an empty catalogue |
<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" provenance="docs/en/guide.md" version="demo-v2" -->
| `add(String)` | Append text |
<!-- cjdoc-bind target="pocketkit.TextCatalog.size" selector="signature:public prop size: Int64" provenance="docs/en/guide.md" version="demo-v2" -->
| `size` | Check the entry count |

Save this program as `src/main.cj`. It must print `PASS guide-store-read`.
See [index error handling](#check-the-index) for the bounds and exceptions of indexed reads.

```cangjie
package guide_caller

import pocketkit.TextCatalog

func check(condition: Bool): Unit {
    if (!condition) { throw IllegalStateException("guide check failed") }
}

main(): Int64 {
    let catalog = TextCatalog()
    catalog.add("hello")
    check(catalog.size == 1)
    check(catalog.at(0) == "hello")
    println("PASS guide-store-read")
    return 0
}
```

## Keep a snapshot

A snapshot retains its original entries without sharing the catalogue's internal container.
After clearing, check that the catalogue is empty and every original snapshot entry remains.

| Precisely associated API | Use in this task |
| --- | --- |
<!-- cjdoc-bind target="pocketkit.TextCatalog.init" selector="signature:public init(entries: Array<String>)" provenance="docs/en/guide.md" version="demo-v2" -->
| `TextCatalog(Array<String>)` | Construct from an array |
<!-- cjdoc-bind target="pocketkit.TextCatalog.snapshot" selector="signature:public func snapshot(): Array<String>" provenance="docs/en/guide.md" version="demo-v2" -->
| `snapshot()` | Take an independent snapshot |
<!-- cjdoc-bind target="pocketkit.TextCatalog.clear" selector="signature:public func clear(): Unit" provenance="docs/en/guide.md" version="demo-v2" -->
| `clear()` | Clear the original catalogue |

Replace `src/main.cj` with this complete program. It must print `PASS guide-snapshot-clear`.

```cangjie
package guide_caller

import pocketkit.TextCatalog

func check(condition: Bool): Unit {
    if (!condition) { throw IllegalStateException("guide check failed") }
}

main(): Int64 {
    let catalog = TextCatalog(["alpha", "beta"])
    let saved = catalog.snapshot()
    catalog.clear()
    check(catalog.size == 0)
    check(saved.size == 2)
    check(saved[0] == "alpha" && saved[1] == "beta")
    println("PASS guide-snapshot-clear")
    return 0
}
```

## Check the index

`at` raises `IllegalArgumentException` for a negative or out-of-range index. Use `tryAt`, which returns `None`, when absence is expected.
The integer `add` overload defaults to decimal. An unsupported `radix` must be rejected without appending an entry.

| Precisely associated API | Use in this task |
| --- | --- |
<!-- cjdoc-bind target="pocketkit.TextCatalog.at" selector="signature:public func at(index: Int64): String" provenance="docs/en/guide.md" version="demo-v2" -->
| `at(Int64)` | Read an index and catch errors |
<!-- cjdoc-bind target="pocketkit.TextCatalog.tryAt" selector="signature:public func tryAt(index: Int64): ?String" provenance="docs/en/guide.md" version="demo-v2" -->
| `tryAt(Int64)` | Represent absence as an optional value |
<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: Int64, radix!: Int64 = 10): Unit" provenance="docs/en/guide.md" version="demo-v2" -->
| `add(Int64, radix: Int64)` | Check the decimal default and rejection |

Replace `src/main.cj` with this complete program. It must print `PASS guide-index-errors`.

```cangjie
package guide_caller

import pocketkit.TextCatalog

func check(condition: Bool): Unit {
    if (!condition) { throw IllegalStateException("guide check failed") }
}

main(): Int64 {
    let catalog = TextCatalog(["alpha"])
    var rejected: Int64 = 0
    for (index in [-1, 1]) {
        try {
            catalog.at(index)
        } catch (e: IllegalArgumentException) {
            rejected++
        }
        check(catalog.tryAt(index) == None)
    }
    check(rejected == 2 && catalog.size == 1)
    check(catalog.tryAt(0) == Some("alpha"))
    catalog.add(42)
    check(catalog.at(1) == "42" && catalog.size == 2)
    try {
        catalog.add(7, radix: 16)
    } catch (e: IllegalArgumentException) {
        rejected++
    }
    check(rejected == 3 && catalog.size == 2 && catalog.at(1) == "42")
    println("PASS guide-index-errors")
    return 0
}
```

## Close the reading session

The caller owns and must close the **in-memory session** returned by `openText`.
It is not an OS file descriptor and holds no network connection or background thread.
EOF returns `None` without closing. Repeated `close` is safe; `read` and `rewind` reject a closed session without reopening it.
The `finally` block also closes the session if a check fails.

| Precisely associated API | Use in this task |
| --- | --- |
<!-- cjdoc-bind target="pocketkit.io.openText" selector="signature:public func openText(text: String): TextReader" provenance="docs/en/guide.md" version="demo-v2" -->
| `openText(String)` | Open an in-memory session |
<!-- cjdoc-bind target="pocketkit.io.TextReader.read" selector="signature:public func read(): ?String" provenance="docs/en/guide.md" version="demo-v2" -->
| `read()` | Read in order and observe EOF |
<!-- cjdoc-bind target="pocketkit.io.TextReader.rewind" selector="signature:public func rewind(): Unit" provenance="docs/en/guide.md" version="demo-v2" -->
| `rewind()` | Return to the first line |
<!-- cjdoc-bind target="pocketkit.io.TextReader.close" selector="signature:public func close(): Unit" provenance="docs/en/guide.md" version="demo-v2" -->
| `close()` | Close idempotently |
<!-- cjdoc-bind target="pocketkit.io.TextReader.closed" selector="signature:public prop closed: Bool" provenance="docs/en/guide.md" version="demo-v2" -->
| `closed` | Check lifetime state |

Replace `src/main.cj` with this complete program. It must print `PASS guide-reader-close`.

```cangjie
package guide_caller

import pocketkit.io.openText

func check(condition: Bool): Unit {
    if (!condition) { throw IllegalStateException("guide check failed") }
}

main(): Int64 {
    let reader = openText("first\nsecond")
    try {
        check(reader.read() == Some("first"))
        check(reader.read() == Some("second"))
        check(reader.read() == None && reader.read() == None)
        check(!reader.closed)
        reader.rewind()
        check(reader.read() == Some("first"))
        reader.close()
        reader.close()
        check(reader.closed)
        var rejected: Int64 = 0
        try { reader.read() } catch (e: IllegalStateException) { rejected++ }
        try { reader.rewind() } catch (e: IllegalStateException) { rejected++ }
        check(rejected == 2 && reader.closed)
    } finally {
        reader.close()
    }
    println("PASS guide-reader-close")
    return 0
}
```

Guide execution evidence is recorded separately from source `@example` reports. Ordinary Markdown fences do not automatically become product doctests.
The version switcher also offers the historical demo-v1 guide. Use that version's APIs there rather than applying these v2 programs to v1.

[Back to the project introduction](../index.md)
