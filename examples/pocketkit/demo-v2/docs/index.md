# PocketKit demo-v2

这是同一个 PocketKit 库的第二个教学快照，不是 cjdoc 或仓颉标准库的发布版本。

TextCatalog 保存文本目录，pocketkit.parsing 提供明确不支持完整 CSV 的分隔解析，
pocketkit.io 展示调用方拥有的内存阅读会话。源码契约与 AST 已知事实分别展示，
unknown、partial 和 ambiguous 不会被构建脚本改写。

This is the second teaching snapshot of the same PocketKit library. It contains an ordered text
catalogue, a deliberately small delimited-text parser and an explicitly closed in-memory reader.
It is not a released version of cjdoc or the standard library.

[目录与资源入门 / Catalogue and lifetime](guide.md)

与 demo-v1 相比：新增 nonEmpty，删除 legacyCount，整数 add 重载增加命名默认参数 radix，
并澄清 snapshot 的说明。这些变化由原生 API diff 实际比较，不以本段文字代替报告。

The native API diff is the source of compatibility classifications. This guide is explanatory only.
