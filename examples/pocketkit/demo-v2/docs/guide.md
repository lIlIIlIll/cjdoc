# 目录与资源入门

用 PocketKit **0.2.0** 教学快照完成保存文本、保留快照、处理索引错误和关闭阅读会话四项任务。
这四项是本教程的练习，不是全库核心任务清单。以下程序在 **Cangjie STS 1.2.0** 上验证。

## 准备调用者项目

先安装 Cangjie STS 1.2.0，确认 `cjc -v` 和 `cjpm -v` 可用。取得本仓库源码后，
保留 `examples/pocketkit/demo-v2` 与 `examples/pocketkit/support-v1` 的相对位置。
调用者只需要 SDK 和这些库源码，不需要 cjdoc binary、stdx 或复现文档站点。

在 `examples/pocketkit/guide-caller` 新建目录，将下列内容保存为该目录的 `cjpm.toml`。
`pocketkit` 是 static path dependency，路径相对于这份清单。

```toml
[package]
cjc-version = "1.2.0"
name = "guide_caller"
version = "1.0.0"
output-type = "executable"

[dependencies]
pocketkit = { path = "../demo-v2", output-type = "static" }
```

在调用者目录中新建 `src` 子目录，并将下面某一节的**完整程序**保存为 `examples/pocketkit/guide-caller/src/main.cj`。
四个程序应每次单独替换 `src/main.cj`，不要把它们拼接在同一文件中。
每次都在 `examples/pocketkit/guide-caller` 工作目录运行同一条命令：

```sh
cjpm run --build-args "--jobs 1"
```

构建可能先打印状态行；成功运行必须打印该节给出的唯一 `PASS guide-…` 标记。
编译或断言失败不算成功。以下都是单线程程序；`TextCatalog` 和 `TextReader` 不提供内部同步，
并发调用需要调用者按 API 作者的说明安排同步。

## 保存并读取文本

构造空目录并调用 `String` 重载追加原样文本，索引从零开始。

| 精确关联的 API | 本节用途 |
| --- | --- |
<!-- cjdoc-bind target="pocketkit.TextCatalog.init" selector="signature:public init()" provenance="docs/guide.md" version="demo-v2" -->
| `TextCatalog()` | 构造空目录 |
<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" provenance="docs/guide.md" version="demo-v2" -->
| `add(String)` | 追加文本 |
<!-- cjdoc-bind target="pocketkit.TextCatalog.size" selector="signature:public prop size: Int64" provenance="docs/guide.md" version="demo-v2" -->
| `size` | 核对条目数 |

将以下程序保存为 `src/main.cj`，运行后应打印 `PASS guide-store-read`。
按索引读取的边界和异常见[索引失败处理](#选择索引失败的处理方式)。

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

## 保留快照再清空

快照保留取得时的元素，不共享目录内部容器。清空后检查原目录为空，并检查快照的全部原元素。

| 精确关联的 API | 本节用途 |
| --- | --- |
<!-- cjdoc-bind target="pocketkit.TextCatalog.init" selector="signature:public init(entries: Array<String>)" provenance="docs/guide.md" version="demo-v2" -->
| `TextCatalog(Array<String>)` | 从数组构造目录 |
<!-- cjdoc-bind target="pocketkit.TextCatalog.snapshot" selector="signature:public func snapshot(): Array<String>" provenance="docs/guide.md" version="demo-v2" -->
| `snapshot()` | 取得独立快照 |
<!-- cjdoc-bind target="pocketkit.TextCatalog.clear" selector="signature:public func clear(): Unit" provenance="docs/guide.md" version="demo-v2" -->
| `clear()` | 清空原目录 |

用以下完整程序替换 `src/main.cj`，运行后应打印 `PASS guide-snapshot-clear`。

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

## 选择索引失败的处理方式

`at` 对负索引或越界抛出 `IllegalArgumentException`；如果不存在是正常情况，使用返回 `None` 的 `tryAt`。
整数 `add` 的默认参数按十进制追加；非法 `radix` 必须拒绝，且不追加任何条目。

| 精确关联的 API | 本节用途 |
| --- | --- |
<!-- cjdoc-bind target="pocketkit.TextCatalog.at" selector="signature:public func at(index: Int64): String" provenance="docs/guide.md" version="demo-v2" -->
| `at(Int64)` | 按索引读取及捕获错误 |
<!-- cjdoc-bind target="pocketkit.TextCatalog.tryAt" selector="signature:public func tryAt(index: Int64): ?String" provenance="docs/guide.md" version="demo-v2" -->
| `tryAt(Int64)` | 用可选值表示不存在 |
<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: Int64, radix!: Int64 = 10): Unit" provenance="docs/guide.md" version="demo-v2" -->
| `add(Int64, radix: Int64)` | 核对十进制默认值和拒绝路径 |

用以下完整程序替换 `src/main.cj`，运行后应打印 `PASS guide-index-errors`。

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

## 关闭阅读会话

调用者负责关闭 `openText` 返回的**内存会话**；它不是 OS 文件描述符，也不持有网络连接或后台线程。
EOF 返回 `None`，不等于已关闭。`close` 可重复调用；关闭后 `read` 和 `rewind` 都拒绝，且不会重新打开会话。
下面用 `finally` 保证调用者在检查过程失败时也关闭会话。

| 精确关联的 API | 本节用途 |
| --- | --- |
<!-- cjdoc-bind target="pocketkit.io.openText" selector="signature:public func openText(text: String): TextReader" provenance="docs/guide.md" version="demo-v2" -->
| `openText(String)` | 打开内存会话 |
<!-- cjdoc-bind target="pocketkit.io.TextReader.read" selector="signature:public func read(): ?String" provenance="docs/guide.md" version="demo-v2" -->
| `read()` | 顺序读取和 EOF |
<!-- cjdoc-bind target="pocketkit.io.TextReader.rewind" selector="signature:public func rewind(): Unit" provenance="docs/guide.md" version="demo-v2" -->
| `rewind()` | 回到第一行 |
<!-- cjdoc-bind target="pocketkit.io.TextReader.close" selector="signature:public func close(): Unit" provenance="docs/guide.md" version="demo-v2" -->
| `close()` | 幂等关闭 |
<!-- cjdoc-bind target="pocketkit.io.TextReader.closed" selector="signature:public prop closed: Bool" provenance="docs/guide.md" version="demo-v2" -->
| `closed` | 核对生命周期状态 |

用以下完整程序替换 `src/main.cj`，运行后应打印 `PASS guide-reader-close`。

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

指南程序的执行证据与源码 `@example` 报告分开记录；普通 Markdown 围栏不自动成为产品 doctest。
版本切换器还保留 demo-v1 历史指南。应使用该版本的 API，不要把本页的 v2 程序套用到 v1。

[返回项目介绍](index.md)
