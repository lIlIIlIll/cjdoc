```text
# Example code
```
# Getting started

Choose a package from the API index, then use the symbol page for signatures, parameters, and source context.

<!-- cjdoc-bind target="html_reference_core.ReferenceBox" selector="type" provenance="docs/guide.md" version="fixture-v1" language="</span><a href=phish>click</a>" -->
<!-- cjdoc-bind target="html_reference_core.ReferenceBox.label" selector="member" provenance="docs/guide.md" version="fixture-v1" -->
<!-- cjdoc-bind target="html_reference_core.HiddenGuideTarget" selector="type" -->
<!-- cjdoc-bind not-target="html_reference_core.ReferenceBox" selector="type" -->
<!-- cjdoc-bind selector="type" -->
````cangjie
let answer = referenceBox(42)
```
<!-- cjdoc-bind target="html_reference_extra.ExtraBox" selector="type" -->
````

## Review multiline output

```cangjie
println("  <script>globalThis.exampleOutputRan = true</script>\tvalue")
println("")
for (line in 3..=13) { println(line) }
```

```output layout=prose
  <script>globalThis.exampleOutputRan = true</script>	value

3
4
5
6
7
8
9
10
11
12
13
```

The following result is shown on its own. Its tab-delimited columns should stay on one line.

```output
id:		0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```
