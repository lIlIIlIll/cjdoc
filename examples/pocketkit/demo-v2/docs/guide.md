# 目录与资源入门 / Catalogue and lifetime

先创建目录，追加文本，再按位置读取。显式绑定的是 **String 重载**，不是同名的整数重载。
Create a catalogue, append a string, and read the first entry. The binding below selects the **String overload**.

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" provenance="docs/guide.md" version="demo-v2" -->

```cangjie
import pocketkit.*
main() {
    let catalog = TextCatalog()
    catalog.add("hello")
    assert(catalog.at(0) == "hello")
}
```

从关联 API 进入具体重载后，通过该成员的相关指南回到这里。
这是页面与 API 的关联，不是完整外置契约合并。源码中的 @example 有真实执行报告；
不能凭指南中存在代码块声称它被执行过。

Follow the explicit API binding and return via the member's related guide. This is a page association,
not a complete external-contract merge. Execution evidence belongs to the source @example, not to this Markdown fence.

## 阅读器责任 / Reader ownership

<!-- cjdoc-bind target="pocketkit.io.TextReader.read" selector="member" provenance="docs/guide.md" version="demo-v2" -->

从 openText 的返回类型进入 TextReader，再查看其 Readable 接口。关闭是幂等的，
关闭后读取会抛出异常。阅读器只管理内存会话，不管理文件描述符。

Follow openText → TextReader → Readable. The caller owns the in-memory session; close is idempotent,
and reading a closed session throws. There is no operating-system file descriptor to close.

## 复现与本地生成 / Reproduce and author locally

本页只讲如何使用 PocketKit。安装 SDK、复现展示产物与本地 `serve` 属于维护者职责，
见 [复现与本地生成 / Reproduce and author locally](reproduce.md)、
[SDK 与工具链要求 / SDK and toolchain](../../../README.md)。
This page covers using PocketKit only. Installing the SDK, reproducing showcase artifacts and the
local `serve` workflow are maintainer tasks: see the reproduction guide.

[返回项目指南 / Project guide](index.md)
