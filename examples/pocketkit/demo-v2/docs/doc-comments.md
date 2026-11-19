# 文档注释示例

把下面的写法放进声明紧邻的 `/** ... */` 注释，再打开每节的「相关 API」对照结果。这里的围栏展示要写的源码；真正可检查的用例在 API 的 `@example` 中。

- 说明 API：[参数与返回值](#参数与返回值)、[行为契约](#行为契约)、[弃用与版本](#弃用与版本)。
- 组织内容：[提示与列表](#提示与列表)、[示例与输出](#示例与输出)、[分组与分类](#分组与分类)。
- 发布之前：[提供译文](#提供译文)、[写错怎么办](#写错怎么办)。

## 参数与返回值

给每个参数一条说明、给返回值一条说明。异常可写多条；此处的 `index-range` 把同一个越界条件的两种语言配成一条。

```text
@param index 从零开始的索引。
@param[lang=en] index The zero-based index.
@return 保存在该位置的文本。
@return[lang=en] The text stored at that position.
@throws[id=index-range] IllegalArgumentException `index` 小于 0 或大于等于 `size`。
@throws[lang=en,id=index-range] IllegalArgumentException `index` is negative or is not smaller than `size`.
```

`at` 的参数、返回和异常各有自己的区域。遇到命名默认参数也是只写参数名：`join` 的源码参数是 `separator!: String = ","`，只写 `@param separator 分隔符，默认是逗号，不进行转义。`，生成页会显示 `separator: String = ","`。在[提示与列表](#提示与列表)打开 `join` 核对。

<!-- cjdoc-bind target="pocketkit.TextCatalog.at" -->

用 `{@link …}` 在正文中说明两个同名类型的区别；用 `@see` 把相关 API 列在「另请参阅」，见[弃用与版本](#弃用与版本)。

```text
返回 {@link pocketkit.parsing.Token}，不是 {@link pocketkit.io.Token}。
```

`parse` 的详细说明中两个 `Token` 分别链接到各自包的声明。

<!-- cjdoc-bind target="pocketkit.parsing.parse" -->

## 行为契约

用契约写清调用前后的条件、成本和失败时的状态。`at` 和 `contains` 各展示一项契约，`add` 的整数重载和 `TextReader` 则按项列出多项契约。先把下面的行放到对应声明，别把所有约束堆进同一段正文。

```text
@precondition 0 <= index < size。
@precondition[lang=en] 0 <= index < size.
```

前置条件显示在[参数与返回值](#参数与返回值)的 `at` 页面。字符串 `add` 的后置条件是 `@postcondition size 比调用前增加一。`；译文是 `@postcondition[lang=en] size increases by one.`。打开[提供译文](#提供译文)中的字符串重载可看到单项标题。

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

`@error` 说明失败时目录保持不变；`@throws` 说明具体抛什么。文档会显示两者，不会自动执行这些约束。要检查行为，另外编写运行示例。

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

打开类型页的「行为约束」对照四项，向下可看到读取到末尾以及重复关闭的运行示例。

<!-- cjdoc-bind target="pocketkit.io.TextReader" -->

## 提示与列表

每个标签各生成一个提示框，不合并同等级，也不按等级重排。`join` 的六个提示依次说明顺序、多字符分隔符、不转义、两种空结果、不可还原、换行拆分日志。下面各摘一条，并给第一条配上译文：

```text
@note[id=join-order] 连接结果保留条目的插入顺序和重复项。
@note[lang=en,id=join-order] The result preserves insertion order and duplicate entries.
@warning[id=join-csv] 条目中的逗号、引号和换行不会转义。生成 CSV 时请使用专用编码器。
@danger[id=join-backup] 不要用连接结果覆盖原始数据。例如，使用默认分隔符时，`["a,b", "c"]` 和 `["a", "b,c"]` 都会得到 `a,b,c`，无法还原。
```

<!-- cjdoc-bind target="pocketkit.TextCatalog.join" -->

如果要在**同一个框**内分条，照抄 `window` 的换行及缩进。这里会看到一个两项无序列表和一个两项有序列表：

```text
@note[id=window-empty] + 在起点有效时，`limit: 0` 返回空窗口。
+
  读取窗口不会移除或重排目录里的条目。

@warning[id=window-pagination] 1. **校验起点：** `start == size` 返回空窗口，`start > size` 会抛出异常。
2. **按实际长度读取：** 末页可能少于 `limit` 项，请按返回数组的长度遍历。
```

普通 `- 第二项` 会成为框外的列表。框内不要插空行；把两个编号写在同一物理行只会得到一段文字。

<!-- cjdoc-bind target="pocketkit.TextCatalog.window" -->

指南 Markdown 用顶层引用，不用 `@note` 等源码标签。把标记单独放在第一行，正文另起一行：

```markdown
> [!NOTE]
> 用提示记录容易忽略的细节。

> [!WARNING]
> 用警告说明误用的后果。

> [!CAUTION]
> 用危险提示标明无法挽回的后果。
```

> [!NOTE]
> 用提示记录容易忽略的细节。

> [!WARNING]
> 用警告说明误用的后果。

> [!CAUTION]
> 用危险提示标明无法挽回的后果。

下面仍是普通引用，没有名为 `[!DANGER]` 的标记：

> [!DANGER]
> 这段文字仍然是引用。

## 示例与输出

每个 `@example` 是单独的用例，默认只展示；显式加 `--check-examples` 才编译。同一用例可以把准备步骤和调用分成多个小写 `cangjie` 围栏，变量可跨围栏使用。另一个用例从头开始。

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

`{run}` 编译并执行，要求正常退出；`output` 是**你写下的预期**，有围栏才核对标准输出。在[提示与列表](#提示与列表)打开 `window`，可看到四个独立用例：分页、默认值与短末页、空窗口、越界。`join` 的用例会显示默认逗号、自定义分隔符、空分隔符和空目录的结果。

用 `{must-pass}` 只查编译，用 `{must-fail}` 要求错误来自片段本身。没有标题或指令也可以写示例：`contains` 的无标题示例只在显式检查时编译，见[行为契约](#行为契约)。

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

到[弃用与版本](#弃用与版本)打开 `requireFirstText`，还可看到一个运行用例打印 `alpha`，捕获两种异常并分行打印异常类型。编译示例没有输出约定，空 `output` 只用于要求运行保持安静。

API 默认把代码和输出放在同一个框里。[首页快照例](index.md)用 `output layout=prose` 把输出紧贴在代码下方。需要在宽屏并排比较短片段时，把 `output` 围栏的首行改成 ` ```output layout=side-by-side `，窄屏仍先读代码：

```cangjie
let catalog = TextCatalog(["a", "b"])
println(catalog.join(separator: " / "))
```

```output layout=side-by-side
a / b
```

## 弃用与版本

`requireFirstText` 是教学用的弃用例，不要把弃用标记贴到它推荐的 `first()` 上。用显式摘要控制简述，用详细说明写两个段落和一份列表：

```text
@summary 读取第一条非空文本；仅用于演示文档注释。
@description 这个旧式入口把两种缺失情况转换为异常。新代码应直接调用 `catalog.first()`。

它只读取第一项，不会跳过空条目去找下一项。

- 空目录没有第一项。
- 空字符串是已有条目，但不能作为结果返回。

@param catalog 要读取的文本目录。
@return 第一条文本，原样返回且不为空。
@throws[id=empty-catalogue] IllegalStateException 目录中没有条目。
@throws[id=blank-entry] IllegalArgumentException 第一条文本是空字符串。
@deprecated 改用 `catalog.first()`：`None` 表示空目录，`Some("")` 表示首项为空；按调用方需要分别处理，其他 `Some(text)` 直接取出 `text`。
@see pocketkit.TextCatalog.first
@see pocketkit.TextCatalog.isEmpty
@since 0.2.0
@author PocketKit
@author Documentation team
@version example-1
```

页面上有两行异常、两个作者、两条「另请参阅」链接及可执行的弃用替代建议。`@since` 是引入该 API 的版本；`@version` 是作者给此声明写的版本元数据，不控制站点的版本切换。引入版本和作者版本各写一项，作者可写多项。

<!-- cjdoc-bind target="pocketkit.authoring.requireFirstText" -->

## 分组与分类

在 `TextReader.read` 上写一组和两个标签。重复的 `cursor` 会去重；在 `rewind` 上用同一组的简写：

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

在 `cjdoc.toml` 为相同包、类型和 ID 注册组标题和顺序。标签只写 ID，双语显示名放在 TOML：

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

组内有 `read` 和 `rewind`；`read` 的「游标」只显示一次。在类型页的成员筛选输入 `tag:cursor tag:reading`，只剩同时拥有两项标签的 `read`。清空筛选恢复其他成员。

<!-- cjdoc-bind target="pocketkit.io.TextReader.read" -->

<!-- cjdoc-bind target="pocketkit.io.TextReader.rewind" -->

## 提供译文

在 `cjdoc.toml` 配置 `[i18n]` 后，无语言标记的作者文字和示例都属于默认语言：

```toml
[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"
```

- **配对**：`at` 用 `index` 配对参数、用 `index-range` 配对异常（见[参数与返回值](#参数与返回值)）；`join` 用同一等级、同一个 `join-order` 配对两条提示（见[提示与列表](#提示与列表)）。
- **缺译回退**：切到 `join` 的英文页，`separator` 仍显示中文说明并标记缺译。补 `@param[lang=en] separator The separator, defaulting to a comma. Entries are not escaped.` 即可提供译文。
- **未配对的独立用例**：下面两个 `add(String)` 示例即使同名也不会互相翻译。两条都会被 `--check-examples` 检查，不共享变量。打开对应语言页查看 `hello` 或保留空条目后的 `count: 1`、`bytes: 0`。

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

没有显式 `@summary` 时，首个顶层普通段落是摘要；其余正文是详细说明。像[弃用与版本](#弃用与版本)那样写 `@summary` 和 `@description` 可分别指定。可本地化的说明可以有多段及列表；`@group`、`@tag` 是单行共享元数据，不加 `[lang=...]`，参见[分组与分类](#分组与分类)。

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" -->

## 写错怎么办

以下是排错用的源码，不是可执行用例。先看表现，再把右侧的正确写法放回声明的注释。

- **提示成了正文**：`@Warning 校验起点。` 不识别；在 `/** ... */` 的顶层写 `@warning 校验起点。`。即使拼写正确，围栏里的标签也只是代码，如下所示。

  ```text
  @warning 校验起点。
  ```

- **空提示（`CJDOC3117`）**：只写 `@note` 不会出现空框；改成 `@note 连接结果保留条目顺序。`。
- **提示 ID 冲突（`CJDOC3118`）**：`@note[id=order] 保留顺序。` 与 `@warning[lang=en,id=order] The result preserves order.` 不会配对；把后者改成 `@note[lang=en,id=order] The result preserves order.`。不同提醒则各自用不同 ID。
- **异常 ID 冲突（`CJDOC3114`）**：把 `@throws[id=first] IllegalStateException 目录为空。` 和 `@throws[id=first] IllegalArgumentException 首项为空。` 写在一起会保留为独立条目；用 `@throws[id=empty-catalogue] IllegalStateException 目录为空。` 和 `@throws[id=blank-entry] IllegalArgumentException 首项为空。` 分开。
- **共享标签被翻译（`CJDOC3112`）**：`@tag[lang=en] cursor` 无效；写 `@tag cursor`，在 `[metadata.tags.titles]` 为它写 `en = "Cursor"`。
- **参数或返回字段不匹配**：在 `at` 写 `@param position 起点。` 找不到参数（`CJDOC3109`）；改成 `@param index 从零开始的索引。`。同语言的两条 `@return` 合并成 `@return 保存在该位置的文本。`。普通单语重复返回是 `CJDOC3003`；启用本地化后的同语言字段冲突是 `CJDOC3106`。

检查示例时，优先检查围栏，再检查指令和实际输出：

1. **没有可检查的代码（`CJDOC3032`）**：`cj` 有高亮但不检查；只写 `output`，或 `cangjie` 围栏为空，也算没有代码。有指令时还报 `CJDOC3070`。把 ` ```cj ` 改为非空的小写 ` ```cangjie ` 或 `~~~cangjie` 围栏，例如放入 `println(catalog.at(0))`（先按[提供译文](#提供译文)准备 `catalog`）。
2. **输出围栏位置不对（`CJDOC3033`）**：已有可检查代码时，`@example 追加后按位置读取 {must-pass}` 配 `output`，或 `{run}` 下写两份 `output` 都无效。改成 `@example 追加后按位置读取 {run}`，只留一个 `output` 围栏；若只编译则删掉 `output`。
3. **输出不匹配（`CJDOC3072`）**：在中文 `add(String)` 用例写 `HELLO`，而程序打印的是 `hello`。中间的空格、标点及换行也必须一致。保持代码行为不变时，把 `output` 改回 `hello`（不是修改打印来迎合错字）。

用诊断中的用例标题定位；无标题时找限定名，例如 `pocketkit.TextCatalog.contains`。只剩 warning 时，`--deny-warnings` 也会令检查失败。完整指令见[文档注释参考](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/doc-comments.md#示例)，内存、时间、数量上限见[检查示例](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-examples.md#资源上限)。
