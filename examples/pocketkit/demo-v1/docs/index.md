# PocketKit demo-v1

用一个文本目录，练习追加、读取和保留快照。`TextCatalog` 保留条目的插入顺序，
允许重复值和空字符串；简单分隔解析与内存阅读会话放在各自的包中。

```cangjie
import pocketkit.*

main() {
    let catalog = TextCatalog()
    catalog.add("hello")
    let saved = catalog.snapshot()
    catalog.clear()
    assert(saved[0] == "hello")
}
```

实例没有内部同步，并发读写需要调用方安排同步。指南提供逐步操作，API 参考保留完整签名与调用条件。

## 教学快照的边界

这是 PocketKit 的第一个教学快照，不是 cjdoc 或仓颉标准库的发布版本。
`pocketkit.parsing` 不支持完整 CSV，`pocketkit.io` 只管理内存会话。
语义未知、部分可用和歧义状态会保留在文档中。

本教学库有意保留部分摘要和示例缺项。例如 `first`、`last` 和 `isEmpty` 只有返回值说明，
空白摘要不表示这些 API 没有行为说明；质量报告也不等于契约正确性证明。
