# PocketKit：可复现的 cjdoc 示例库

MIT，许可证见 LICENSE。此库由 cjdoc 仓库维护，不是 std 的镜像或 cjdoc 的发行版本。

`demo-v1` 和 `demo-v2` 是同一个 `pocketkit` 包的教学快照，分别使用 0.1.0/0.2.0 示例包版本。
库包含有二十多个成员的 TextCatalog、pocketkit.parsing 解析包和 pocketkit.io 内存阅读会话。
`support-v1` 是独立生成的固定依赖文档集；它是显式声明的本地包依赖；示例不需要调用其运行时代码。
`diagnostics` 隔离故意失败、缺失和歧义场景，不属于入门流程。

This owned MIT example covers collection/parsing APIs, named/default parameters, nested generics,
optional results, exception boundaries, source-backed extension constraints and explicit reader ownership.
The two snapshot names are educational labels, not official tool or standard-library releases.

## 复现 / Reproduce

安装 SDK 1.2.0 和与下载清单 revision 对应的 cjdoc。源档案保留 `examples/pocketkit` 目录结构。
从源码档案根目录执行：

```sh
python3 examples/pocketkit/reproduce.py --cjdoc /absolute/path/to/cjdoc --output ./generated --locale both
```

复现脚本实际运行 generate、API surface diff 和 versions compose；独立依赖的索引来自该脚本先生成的
support-v1。配置受版本控制，不会被整体覆盖。输出目录必须不存在，脚本不删除已有用户目录。

该依赖索引采用当前 `cjdoc.symbol-index/2`；`support-v1` 是文档展示版本，
不替代包的 API 版本或依赖身份。复现仍验证索引 schema 和展示版本，不降级成旧索引格式。

Generated core API pages use the same CLI, sources and configurations as the published showcase.
The Pages homepage and human-readable report presentation are publication layers, not handwritten API implementations.

`demo-v1` / `demo-v2` 通过 `[i18n]` 和 `@tag[lang=en]` 保存作者提供的正文翻译。
`--locale both` 是复现脚本选项；它调用原生 `generate --all-languages`，每个版本分析一次，
再用原生站点清单组合语言与版本。原生 CLI 的 locale 值仍只有 `zh-CN` / `en`。
入门指南有独立英文文件，TextCatalog 提供真实不同的摘要、参数、返回值、异常和行为契约文字。
尚未翻译的字段保留带语言标记的原文；示例中的缺译与 `diagnostics` 的故意失败分别报告。

## 边界 / Boundaries

源码作者说明不等于类型检查器证明。partial/unavailable/ambiguous 仍保持原状态。
指南绑定演示页面关联，不宣传完整外置契约合并。
独立 `check-modes` 包使用原生 `check --check-examples` 验证 `{must-pass}`（只编译）、
`{run}`（运行并检查输出）、`{must-fail}`（预期编译失败）和无代码跳过。
`check-modes/native-check.json` 保留输入摘要、CLI、退出状态和诊断；这是命令整体证据，
不是尚未提供的逐例 machine result。检查必须退出 0，且只能出现一条预期无代码诊断。

原生 `{run}` 使用 10 秒、2,048 MiB 的限制：每个输出流保留前 65,536 bytes，同时排空
并统计完整字节数；超量产生 `CJDOC3075`，超时终止进程树并产生 `CJDOC3073`。
指令示例的编译子进程默认限时 120 秒、每个流仅保留前 8,192 bytes；编译诊断还有
8,192-byte 正文展示预算。这是诊断保留/截断，不是运行输出上限，也不改变实际编译退出码。

Native `{run}` retains 64 KiB per stream while draining and counting all bytes; excess output is an
error, and its 10-second watchdog terminates the process tree. Compiler diagnostics retain only
8 KiB per stream and have a separate display budget. These are native compiler-check limits,
not additional showcase configuration options or individual example-result claims.

阅读器只拥有内存会话，不拥有系统文件描述符。TextCatalog 不提供内部同步。解析函数不是完整 CSV parser。
