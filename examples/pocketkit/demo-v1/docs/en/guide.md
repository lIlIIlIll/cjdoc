# Catalogue and lifetime

Create a catalogue, append values, then keep a snapshot before clearing it.

## Store and read text

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" provenance="authored" -->

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

A snapshot owns its array of entries. Clearing the catalogue preserves the returned snapshot.

## Check the index

<!-- cjdoc-bind target="pocketkit.TextCatalog.at" selector="example" provenance="authored" -->

An invalid index raises `IllegalArgumentException`. Use `tryAt` when absence is expected.
