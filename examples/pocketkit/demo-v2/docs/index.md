# PocketKit demo-v2

- [调用 PocketKit](guide.md)：保存文本、按索引读取、关闭阅读会话。
- [编写文档注释](doc-comments.md)：照抄标签、提示和示例，再打开真实 API 看结果。

`TextCatalog` 按插入顺序保存文本，允许重复值和空字符串；简单分隔解析与内存阅读会话放在各自的包中。

运行下面的代码，清空目录后打印快照的第一项。预期仍得到 `hello`，说明清空没有改变快照。

```cangjie
import pocketkit.*

main() {
    let catalog = TextCatalog()
    catalog.add("hello")
    let saved = catalog.snapshot()
    catalog.clear()
    println(saved[0])
}
```

```output layout=prose
hello
```

实例没有内部同步，并发读写需要调用方安排同步。指南按任务逐步操作，API 参考保留完整签名与调用条件。

## 教学快照的边界

这是 PocketKit 的第二个教学快照，不是 cjdoc 或仓颉标准库的发布版本。
`pocketkit.parsing` 不支持完整 CSV，`pocketkit.io` 只管理内存会话。
语义未知、部分可用和歧义状态会保留在文档中。

本教学库有意保留部分摘要和示例缺项。例如 `first`、`last` 和 `isEmpty` 只写了返回值，
空白摘要不表示这些 API 没有行为说明；质量报告也不等于契约正确性证明。

与 demo-v1 相比，新增 `nonEmpty`，删除 `legacyCount`，整数 `add` 增加命名默认参数 `radix`。
兼容性分类以原生 API diff 为准。安装、构建和本地生成见[复现说明](reproduce.md)。
