# 目录与资源入门

本页按顺序做三件事：创建目录并追加文本、在清空前保留快照、关闭阅读会话。
需要确认调用限制时，从段旁的关联进入具体 API，再返回本节。

## 保存并读取文本

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" provenance="docs/guide.md" version="demo-v1" -->

下面的程序调用 `String` 重载，它原样保存文本；索引从零开始。运行后没有输出，断言通过即成功。

```cangjie
import pocketkit.*

main() {
    let catalog = TextCatalog()
    catalog.add("hello")
    assert(catalog.at(0) == "hello")
}
```

## 保留快照再清空

<!-- cjdoc-bind target="pocketkit.TextCatalog.snapshot" selector="member" provenance="docs/guide.md" version="demo-v1" -->

快照不共享目录内部的容器。清空目录不会删除已经取得的数组内容。

```cangjie
import pocketkit.*

main() {
    let catalog = TextCatalog(["alpha", "beta"])
    let saved = catalog.snapshot()
    catalog.clear()
    assert(saved.size == 2)
    assert(saved[0] == "alpha")
}
```

## 选择索引失败的处理方式

<!-- cjdoc-bind target="pocketkit.TextCatalog.at" selector="member" provenance="docs/guide.md" version="demo-v1" -->

`at` 要求索引位于有效范围；负索引或越界会抛出 `IllegalArgumentException`。
如果索引不存在属于正常情况，使用 `tryAt`：有效索引返回 `Some`，负索引或越界返回 `None`。

## 关闭阅读会话

<!-- cjdoc-bind target="pocketkit.io.TextReader.read" selector="member" provenance="docs/guide.md" version="demo-v1" -->

从 `openText` 的返回类型进入 `TextReader`，再查看它实现的 `Readable` 接口。
调用方负责关闭内存会话；`close` 是幂等操作，关闭后再次读取会抛出异常。
它不持有操作系统文件描述符。

本页代码块只说明用法；要核对示例输出，请到 API 页看作者写的 `@example`。

[返回项目介绍](index.md)
