# Catalogue and lifetime

Create a catalogue, append values, then take a snapshot before clearing it.

## Store and read text

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" provenance="authored" -->

The `String` overload stores text unchanged; indices start at zero. The program prints nothing, so a passing assertion is the success signal.

```cangjie
import pocketkit.*

main() {
    let catalog = TextCatalog()
    catalog.add("hello")
    assert(catalog.at(0) == "hello")
}
```

## Keep a snapshot

<!-- cjdoc-bind target="pocketkit.TextCatalog.snapshot" selector="example" provenance="authored" -->

A snapshot owns its array of entries. Clearing the catalogue keeps the returned snapshot unchanged.

## Check the index

<!-- cjdoc-bind target="pocketkit.TextCatalog.at" selector="example" provenance="authored" -->

An invalid index raises `IllegalArgumentException`. Use `tryAt` when absence is expected.

## Close the reading session

`openText` returns an in-memory session that the caller closes. `close` is idempotent,
`read` and `rewind` reject a closed session, and no operating-system file handle is involved.
Continue from the `openText` return type to `TextReader` and its `Readable` interface.

These fences explain usage. To check expected output, open the `@example` cases on the API pages.
