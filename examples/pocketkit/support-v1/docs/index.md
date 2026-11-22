# Pocket support / 独立依赖文档

这是 PocketKit 自有的独立文档集，文档版本固定为 **support-v1**。它不是仓颉标准库镜像，
也不是任何第三方正式发布的版本。源码与许可证随示例提供。

用它来对照"文档集中引用了另一个文档集"时的行为：本地 `Stamp` 与这里的
`pocket_support.Stamp` 保持各自的身份，指向 `pocket_support.SourceLabel.text` 的链接也只解析到本集。
生成器只读取本地的固定版本 symbol-index，不联网猜测外部目标；相对地址以本集根目录为范围。

This is the independently generated documentation of the owned `pocket_support` example dependency.
Its explicit documentation version is `support-v1`. It is not a mirror of the standard library.
The generator reads only the fixed local symbol-index and never guesses a remote target.
