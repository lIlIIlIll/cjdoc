# PocketKit：可复现的 cjdoc 示例库

MIT，许可证见 LICENSE。此库由 cjdoc 仓库维护，不是 std 的镜像或 cjdoc 的发行版本。

`demo-v1` 和 `demo-v2` 是同一个 `pocketkit` 包的教学快照，分别使用 0.1.0/0.2.0 示例包版本。
库包含有二十多个成员的 TextCatalog、pocketkit.parsing 解析包和 pocketkit.io 内存阅读会话。
`support-v1` 是独立生成的固定依赖文档集；它是文档链接依赖，不是执行示例的运行时依赖。
`diagnostics` 隔离故意失败、缺失和歧义场景，不属于入门流程。

This owned MIT example covers collection/parsing APIs, named/default parameters, nested generics,
optional results, exception boundaries, source-backed extension constraints and explicit reader ownership.
The two snapshot names are educational labels, not official tool or standard-library releases.

## 复现 / Reproduce

安装 SDK 1.1.3 和与下载清单 revision 对应的 cjdoc。源档案保留 `examples/pocketkit` 目录结构。
从源码档案根目录执行：

```sh
python3 examples/pocketkit/reproduce.py --cjdoc /absolute/path/to/cjdoc --output ./generated --locale both
```

复现脚本实际运行 generate、API surface diff 和 versions compose；独立依赖的索引来自该脚本先生成的
support-v1。配置受版本控制，不会被整体覆盖。输出目录必须不存在，脚本不删除已有用户目录。

Generated core API pages use the same CLI, sources and configurations as the published showcase.
The Pages homepage and human-readable report presentation are publication layers, not handwritten API implementations.

## 边界 / Boundaries

源码作者说明不等于类型检查器证明。partial/unavailable/ambiguous 仍保持原状态。
指南绑定演示页面关联，不宣传完整外置契约合并；doctest 只支持实际已有的编译后运行与跳过，
没有 compile-only 或 expected-failure 的成功转换。诊断项目中的 failed 不计入 passed。

阅读器只拥有内存会话，不拥有系统文件描述符。TextCatalog 不提供内部同步。解析函数不是完整 CSV parser。
