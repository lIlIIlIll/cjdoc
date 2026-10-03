# PocketKit demo-v1

这是 PocketKit 库的第一个教学快照，与 demo-v2 来自同一库，不是正式工具或标准库版本。
TextCatalog、pocketkit.parsing 和 pocketkit.io 分别演示目录、解析与内存会话。

This is the first teaching snapshot of the same PocketKit library, not a release of cjdoc or the standard library.

## 教学文档缺项 / Intentional documentation gaps

本教学库保留部分摘要和示例缺项，以展示质量诊断。比如 first、last 和 isEmpty
只有返回值说明，没有独立摘要；空白摘要不表示这些 API 没有行为说明。
质量报告中的缺项是待完善的作者注释，不是生成器已证明没有其他行为或异常。

This teaching library deliberately retains missing summaries and examples for quality diagnostics.
For example, first, last and isEmpty have return documentation but no separate summary.
These are author documentation gaps, not evidence that the APIs have no further behavior or exceptions.

[目录与资源入门 / Catalogue and lifetime](guide.md)

demo-v1 的整数 add 没有 radix 命名参数，并且仍包含 legacyCount。
版本差异的分类以原生 diff 产物为准，不根据这段说明猜测兼容性。
