# Doc comment examples

Put these snippets in the `/** ... */` comment immediately above a declaration. Follow each section's **Related API** links to see what readers get. Fences here show what to write; the checkable `@example` blocks live on the API declarations.

- Describe an API: [Parameters, returns and links](#parameters-returns-and-links), [Behavioral contracts](#behavioral-contracts), [Deprecation and versions](#deprecation-and-versions).
- Organize content: [Alerts and lists](#alerts-and-lists), [Examples and output](#examples-and-output), [Groups and tags](#groups-and-tags).
- Before publishing: [Provide translations](#provide-translations), [Fix common mistakes](#fix-common-mistakes).

## Parameters, returns and links

Document each parameter once and give the result one description. List each exception separately. `index-range` pairs the two descriptions of the same out-of-bounds condition.

```text
@param index 从零开始的索引。
@param[lang=en] index The zero-based index.
@return 保存在该位置的文本。
@return[lang=en] The text stored at that position.
@throws[id=index-range] IllegalArgumentException `index` 小于 0 或大于等于 `size`。
@throws[lang=en,id=index-range] IllegalArgumentException `index` is negative or is not smaller than `size`.
```

`at` has separate areas for the parameter, return value and exception. For a named parameter with a default, still write just the name: the source declares `separator!: String = ","`, the comment says `@param separator 分隔符，默认是逗号，不进行转义。`, and the page displays `separator: String = ","`. Open `join` under [Alerts and lists](#alerts-and-lists) to compare.

<!-- cjdoc-bind target="pocketkit.TextCatalog.at" -->

Use `{@link …}` to distinguish identically named types in a sentence. Use `@see` for entries under **See also**, as in [Deprecation and versions](#deprecation-and-versions).

```text
返回 {@link pocketkit.parsing.Token}，不是 {@link pocketkit.io.Token}。
```

On `parse`, the two `Token` links in the description lead to declarations in different packages.

<!-- cjdoc-bind target="pocketkit.parsing.parse" -->

## Behavioral contracts

Use a contract to describe what a caller must do, what changes after a call, or how failure affects state. The pages for `at` and `contains` show one contract with its own heading. The integer `add` overload and `TextReader` list several contracts separately.

```text
@precondition 0 <= index < size。
@precondition[lang=en] 0 <= index < size.
```

See `at` under [Parameters, returns and links](#parameters-returns-and-links) for the precondition. The string overload uses `@postcondition size 比调用前增加一。` and `@postcondition[lang=en] size increases by one.`; find it under [Provide translations](#provide-translations).

```text
@performance 最多检查 `size` 个条目。
@performance[lang=en] Checks at most `size` entries.
```

<!-- cjdoc-bind target="pocketkit.TextCatalog.contains" -->

```text
@compatibility 旧的单参数调用仍有效，使用默认的十进制。
@compatibility[lang=en] Existing calls with one argument still use decimal.
@error `radix` 不是 10 时，不追加任何条目。
@error[lang=en] A `radix` other than 10 leaves the catalogue unchanged.
@throws IllegalArgumentException radix 不是 10。
```

`@error` describes the unchanged catalogue; `@throws` names the exception. Neither checks the behavior. Write a separate running example if you want to verify it.

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: Int64, radix!: Int64 = 10): Unit" -->

```text
@state 读到末尾时 `read()` 返回 `None`，会话仍然打开。
@state[lang=en] At EOF, `read()` returns `None` and the session stays open.
@invariant 会话一旦关闭就不会重新打开。
@invariant[lang=en] Once closed, the session never reopens.
@concurrency 多个线程共享读取位置时，调用方必须同步访问。
@concurrency[lang=en] Callers must synchronize access when sharing the cursor across threads.
@platform 只读内存文本，不打开文件句柄。
@platform[lang=en] Reads in-memory text without opening a file handle.
```

Find all four contracts on the type page. The example below them reads to EOF and closes the reader twice.

<!-- cjdoc-bind target="pocketkit.io.TextReader" -->

## Alerts and lists

Write one tag per box. Repeated levels stay separate and keep their source order. `join` has six alerts: order, multi-character separators, no escaping, two kinds of empty result, loss of information, and newlines splitting log records. Here is one of each level with its translation:

```text
@note[id=join-order] 连接结果保留条目的插入顺序和重复项。
@note[lang=en,id=join-order] The result preserves insertion order and duplicate entries.
@warning[id=join-csv] 条目中的逗号、引号和换行不会转义。生成 CSV 时请使用专用编码器。
@warning[lang=en,id=join-csv] Commas, quotes, and newlines in entries are not escaped. Use a CSV encoder to produce CSV.
@danger[id=join-backup] 不要用连接结果覆盖原始数据。例如，使用默认分隔符时，`["a,b", "c"]` 和 `["a", "b,c"]` 都会得到 `a,b,c`，无法还原。
@danger[lang=en,id=join-backup] Do not overwrite the original data with this result. With the default separator, `["a,b", "c"]` and `["a", "b,c"]` both produce `a,b,c`, so the original entries cannot be recovered.
```

<!-- cjdoc-bind target="pocketkit.TextCatalog.join" -->

For multiple points **inside one box**, copy the line breaks and indentation from `window`. Each box has two list items, bulleted in the note and numbered in the warning:

```text
@note[lang=en,id=window-empty] + With a valid start, `limit: 0` returns an empty window.
+
  Reading a window does not remove or reorder catalogue entries.

@warning[lang=en,id=window-pagination] 1. **Check the start:** `start == size` returns an empty window; `start > size` throws.
2. **Iterate over the result:** the final page can have fewer than `limit` entries, so use the returned array's length.
```

A plain `- Second point` starts a list outside the box. A blank line ends the alert. Writing two numbers on the same physical line produces one paragraph.

<!-- cjdoc-bind target="pocketkit.TextCatalog.window" -->

In guide Markdown, use a top-level quote instead of a source comment tag. Put the marker on a line of its own, with text on the next quoted line:

```markdown
> [!NOTE]
> Use a note for details readers may miss.

> [!WARNING]
> Use a warning to explain what can go wrong.

> [!CAUTION]
> Use a danger box for consequences readers cannot undo.
```

> [!NOTE]
> Use a note for details readers may miss.

> [!WARNING]
> Use a warning to explain what can go wrong.

> [!CAUTION]
> Use a danger box for consequences readers cannot undo.

This stays a plain quote because `[!DANGER]` is not a recognized marker:

> [!DANGER]
> This text remains a quote.

## Examples and output

Each `@example` is a separate case. Generation displays it; `--check-examples` compiles it. Split setup and calls across lowercase `cangjie` fences within one case to share variables. A new `@example` starts from scratch.

~~~text
@example 按位置与上限取窗口 {run}
```cangjie
let catalog = TextCatalog(["a", "b", "c", "d"])
```
```cangjie
let page = catalog.window(start: 1, limit: 2)
for (entry in page) {
    println(entry.getOrThrow())
}
```

**预期输出 / Expected output**

```output
b
c
```
~~~

`{run}` compiles and runs the case and requires a successful exit. The `output` fence is the stdout **you expect**, not a log. Under [Alerts and lists](#alerts-and-lists), open `window` to see four cases: paginating, default and short pages, empty windows and invalid arguments. `join` shows a default comma, custom and empty separators, and an empty catalogue.

Use `{must-pass}` to compile without running and `{must-fail}` to require a compiler error in the snippet. A title and a directive are both optional. See the untitled, compile-only `contains` case under [Behavioral contracts](#behavioral-contracts).

~~~text
@example
```cangjie
let _ = TextCatalog(["a"]).contains("a")
```
~~~

~~~text
@example 只编译，不运行 {must-pass flags="-O0"}
预期编译通过；不执行这条 `throw`。

```cangjie
throw IllegalStateException("compile only")
```
@example 不存在的 API {must-fail error="missingApi"}
预期片段编译失败，且诊断包含 `missingApi`。

```cangjie
missingApi()
```
@example 不打印也可以核对输出 {run}
```cangjie
let _ = requireFirstText(TextCatalog(["ok"]))
```

**预期输出 / Expected output**

空围栏要求没有标准输出，省略围栏则不比较标准输出。

```output
```
~~~

The first snippet must compile, even though running it would throw. The second must fail to compile with `missingApi` in the diagnostic. Neither has expected stdout. The last runs: an empty `output` fence requires no stdout; omit the fence to check normal exit without comparing stdout. Open `requireFirstText` under [Deprecation and versions](#deprecation-and-versions) to find these cases and a fourth one that prints `alpha` and catches both documented exceptions.

API examples put code and output in one frame by default. The [homepage snapshot example](../index.md) uses `output layout=prose` to attach the output below the code block. For a short comparison on wide screens, start the output fence with ` ```output layout=side-by-side `. Narrow screens still show code first:

```cangjie
let catalog = TextCatalog(["a", "b"])
println(catalog.join(separator: " / "))
```

```output layout=side-by-side
a / b
```

## Deprecation and versions

Both `requireFirstText` and `firstTextOrEmpty` show **Deprecated**. The first uses one `@replacement` tag to link to its replacement. The second has only a source `@Deprecated` annotation, so its page shows the annotation's reason, “An empty catalogue and a blank first entry are indistinguishable.”, as a source note and has no migration link:

```text
@summary[lang=en] Read the first entry; throw if the catalogue is empty or its first entry is an empty string.
@description[lang=en] This legacy entry point turns two missing-value cases into exceptions.

It reads only the first entry and never skips a blank entry to look for the next one.

- An empty catalogue has no first entry.
- An empty string is an entry, but cannot be returned by this function.

@param[lang=en] catalog The text catalogue to read.
@return[lang=en] The first entry, unchanged and non-empty.
@throws[lang=en,id=empty-catalogue] IllegalStateException The catalogue has no entries.
@throws[lang=en,id=blank-entry] IllegalArgumentException The first entry is an empty string.
@replacement pocketkit.TextCatalog.first
@deprecated[lang=en] Handle the three results of `catalog.first()` separately:

- `None`: the catalogue has no entries.
- `Some("")`: the first entry exists but is blank.
- `Some(text)`: the first entry is non-empty; unwrap `text`.

@see pocketkit.TextCatalog.first
@see pocketkit.TextCatalog.isEmpty
@since 0.2.0
@author PocketKit
@author Documentation team
@version example-1
```

In the package table or on the `requireFirstText` page, follow **Use `TextCatalog.first()`** to the replacement. The `@see` links for `first` and `isEmpty` still appear under **See also**. `isEmpty` is not a replacement. Use `@since` for the API's introduction and `@version` for the version recorded by the author. Neither controls version switching on the site.

<!-- cjdoc-bind target="pocketkit.authoring.requireFirstText" -->

<!-- cjdoc-bind target="pocketkit.authoring.firstTextOrEmpty" -->

## Groups and tags

Give `TextReader.read` one group and two tags. The duplicate `cursor` is deduplicated. Give `rewind` the shorthand for the same group:

```text
@group 10-cursor 读取位置
@tag cursor
@tag reading
@tag cursor
```

```text
@group 10-cursor
@tag cursor
```

In `cjdoc.toml`, register the heading and order for the same package, owner and ID. Use tag IDs in comments and set translated display names in TOML:

```toml
[[metadata.groups]]
package = "pocketkit.io"
owner = "pocketkit.io.TextReader"
id = "10-cursor"
title = "读取位置"
order = 10

[metadata.groups.titles]
zh-CN = "读取位置"
en = "Reading position"

[[metadata.tags]]
id = "cursor"
title = "游标"

[metadata.tags.titles]
zh-CN = "游标"
en = "Cursor"

[[metadata.tags]]
id = "reading"
title = "读取"

[metadata.tags.titles]
zh-CN = "读取"
en = "Reading"
```

**Reading position** contains `read` and `rewind`; `read` shows **Cursor** just once. Enter `tag:cursor tag:reading` in the type page's member filter to keep only `read`, which has both tags. Clear the filter to restore the other members.

<!-- cjdoc-bind target="pocketkit.io.TextReader.read" -->

<!-- cjdoc-bind target="pocketkit.io.TextReader.rewind" -->

## Provide translations

In `cjdoc.toml`, set `[i18n]`. Untagged author text and examples then belong to the default language:

```toml
[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"
```

- **Paired**: `at` pairs the parameter by `index` and the exception by `index-range` ([Parameters, returns and links](#parameters-returns-and-links)). `join` pairs the notes with `join-order` because they share an ID and level ([Alerts and lists](#alerts-and-lists)).
- **Fallback**: in English, `join` still shows the Chinese `separator` description with a missing-translation label. To supply the translation, add `@param[lang=en] separator The separator, defaulting to a comma. Entries are not escaped.`
- **Separate examples**: `@example[lang=en]` belongs to English, but is not a translation of another case even if they have matching titles. `--check-examples` checks both independently. Switch between languages on the string overload to see the access example (`hello`) and the empty-entry example (`count: 1`, `bytes: 0`).

~~~text
@example 追加后按位置读取 {run}
```cangjie
let catalog = TextCatalog()
catalog.add("hello")
println(catalog.at(0))
```

**预期输出 / Expected output**

```output
hello
```
@example[lang=en] Keep an empty entry {run}
```cangjie
let catalog = TextCatalog()
catalog.add("")
println("count: ${catalog.size}")
println("bytes: ${catalog.at(0).size}")
```

**Expected output**

```output
count: 1
bytes: 0
```
~~~

Without `@summary`, the first ordinary top-level paragraph is the summary and the rest is the description. Use explicit fields as under [Deprecation and versions](#deprecation-and-versions) to control both. Localizable descriptions can include paragraphs and lists. `@group` and `@tag` are shared, single-line metadata without `[lang=...]`; see [Groups and tags](#groups-and-tags) for display names.

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" -->

## Fix common mistakes

These snippets show what to fix in your source comment. They are not runnable cases.

- **An alert looks like plain text**: `@Warning Check the start.` is not recognized. Write `@warning Check the start.` at the top level of the comment. Even the correct spelling is plain code inside a fence:

  ```text
  @warning Check the start.
  ```

- **Empty alert (`CJDOC3117`)**: `@note` alone produces no box. Write `@note The result preserves insertion order.`
- **Alert ID conflict (`CJDOC3118`)**: `@note[id=order] 保留顺序。` does not pair with `@warning[lang=en,id=order] The result preserves order.` Change the latter to `@note[lang=en,id=order] The result preserves order.` Use different IDs for different alerts.
- **Exception ID conflict (`CJDOC3114`)**: `@throws[id=first] IllegalStateException The catalogue is empty.` and `@throws[id=first] IllegalArgumentException The first entry is empty.` stay separate and trigger a conflict. Use `@throws[id=empty-catalogue] IllegalStateException The catalogue is empty.` and `@throws[id=blank-entry] IllegalArgumentException The first entry is empty.`
- **Localized shared tag (`CJDOC3112`)**: `@tag[lang=en] cursor` is invalid. Write `@tag cursor` and put `en = "Cursor"` in its `[metadata.tags.titles]` table.
- **Parameter or return field mismatch**: on `at`, `@param position Starting position.` names no parameter (`CJDOC3109`); use `@param index The zero-based index.` Merge two `@return` entries in one language into `@return The text stored at that position.` A repeated return in a non-localized comment reports `CJDOC3003`; a same-language field conflict with localization enabled reports `CJDOC3106`.

When an example fails, check the fence, the directives and then the output:

1. **No checkable code (`CJDOC3032`)**: `cj` highlights but is not checked. A lone `output` or an empty `cangjie` fence also has no code. A directive adds `CJDOC3070`. Replace ` ```cj ` with a non-empty, lowercase ` ```cangjie ` or `~~~cangjie` fence. For example, add `println(catalog.at(0))` after the catalogue setup in [Provide translations](#provide-translations).
2. **Invalid output fence (`CJDOC3033`)**: with checkable code present, `{must-pass}` with `output`, or `{run}` with two `output` fences, is invalid. Write `@example Append and read {run}` with one `output` fence, or omit `output` for compile-only.
3. **Output mismatch (`CJDOC3072`)**: the default-language string overload prints `hello`, not `HELLO`. Spaces, punctuation and interior lines also matter. If the code is right, put `hello` back in the `output` fence.

Find the case by its title in the diagnostic; for an untitled case, use the qualified name, such as `pocketkit.TextCatalog.contains`. `--deny-warnings` fails a check even if it only reports warnings. See the [doc comment reference](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/doc-comments.md#示例) for directives and the [example-checking guide](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-examples.md#资源上限) for memory, time and count limits.
