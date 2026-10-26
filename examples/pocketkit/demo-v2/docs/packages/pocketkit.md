# 文本目录

`pocketkit` 用 `TextCatalog` 按插入顺序保存文本，保留重复值和空字符串。
可以按位置读取、替换或删除条目，也可以在修改前取得独立的数组快照。

## 从目录开始

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" provenance="authored" -->

先读[目录与资源入门](../guide.md)，创建目录并追加文本，再比较同名的整数重载。
整数重载只接受 `radix: 10`；需要其他进制时，不能把它当作通用格式化接口。

## 在修改前保留内容

<!-- cjdoc-bind target="pocketkit.TextCatalog.snapshot" selector="member" provenance="authored" -->

`snapshot` 返回不共享内部容器的数组。清空目录后，已经取得的数组仍然保留原条目。
实例没有内部同步；并发读写的同步由调用方安排。

目录以外的示例分别位于 `pocketkit.parsing` 和 `pocketkit.io`：前者只处理简单分隔文本，
后者演示调用方负责关闭的内存阅读会话。包页中的完整声明索引始终提供所有可见入口。
