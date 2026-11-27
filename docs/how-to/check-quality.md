# 检查文档质量并设置门槛

在含 `cjpm.toml` 的项目根运行 `cjdoc check`，找出漏写的摘要、参数或返回值说明。再把覆盖率底线写进 `cjdoc.toml`，让本地和 CI 使用同一个规则。检查只能发现部分结构问题；说明是否符合实际行为，仍须[对照源码复核](review-contracts.md)。

## 1. 运行诊断

当前终端已经[安装 cjdoc](../getting-started/install.md)并加载了 SDK 时，在项目根执行：

```bash
cjdoc check --project .
```

没有诊断时命令可以不输出任何内容。默认只有 error 令命令失败；加 `--deny-warnings` 才把 warning 一并作为失败。可在 `[lint]` 中逐项设置 `off`、`warning`、`error`，见[配置参考](../reference/configuration.md)。

| 诊断码 | 修改哪一处 |
|---|---|
| `CJDOC3034` | 给诊断定位的可见声明添加文档注释 |
| `CJDOC3004` | 为指定参数补 `@param` |
| `CJDOC3036` | 在摘要之后补详细说明 |
| `CJDOC3037` | 为非 `Unit` 返回值补 `@return` |
| `CJDOC3038` | 给公开声明补 `@example` |
| `CJDOC3047` | 摘要整句只重复声明名；改写摘要说明它做什么，或在 `[lint]` 把 `trivial-summary` 设为 `off` |
| `CJDOC3048` | `@param` 说明整句只重复参数名；补充参数含义或取值范围 |
| `CJDOC3049` | `@return` 说明整句只重复返回类型；说明返回值表示什么 |

`CJDOC3047`–`CJDOC3049` 是模板式说明的保守提示，与其它规则一样跟随 `[lint]`：`severity = "off"` 会一并关闭，也可以按规则名单独设为 `off`、`warning` 或 `error`。完整规则表见[配置参考](../reference/configuration.md)。

启用多语言的项目还要处理缺译；见[发布中英文](../tutorials/publish-languages.md)。要编译或运行示例，另加 `--check-examples`。

## 2. 生成覆盖率与质量报告

```bash
cjdoc generate --project . --format coverage --output target/quality-report
```

命令成功后，在 `target/quality-report/coverage/` 打开 `coverage.json` 和 `quality.json`。配置 `[i18n]` 后还会写出 `translations.json`。不要预先创建空输出目录。

`coverage.json` 的 `metrics` 记录七类指标：

| 指标 | 计入分母 | 计入已写 |
|---|---|---|
| `symbols` | 当前受众可见的声明 | 摘要非空 |
| `parameters` | 名称不以 `_` 开头的参数 | `@param` 说明非空 |
| `returns` | 有非 `Unit` 返回值的声明 | `@return` 说明非空 |
| `throws` | 实际写出的 `@throws` 条目 | 说明非空 |
| `examples` | 所有可见声明，没有注释的也计入 | 至少一个说明非空的 `@example` |
| `deprecated` | 实际写出的 `@deprecated` 条目 | 弃用说明非空 |
| `semanticLinks` | 记录的 `@see` 与结构化 Markdown 链接 | 解析成功 |

`total` 是分母，`documented` 是已写数，`percent` 是百分比；分母为 `0` 时记作 `100%`。`packages` 和 `modules` 以同样方式分组。

`quality.json` 中的 `findings` 可帮助找出只重复声明名、参数名或返回类型的模板说明。`symbols` 和 `parameters` 还有 `meaningful` 计数，但不能设为门槛。覆盖率或模板规则通过，都不证明文档说对了。

## 3. 设置持久覆盖率门槛

在项目 `cjdoc.toml` 中增加 `[coverage]`；已有该表时只添加或修改下面的键：

```toml
[coverage]
symbols = 100
parameters = 100
```

- 键名与报告指标对应，其中 `semantic-links` 带连字符。
- 取值是 `0..100` 的整数；其它可用的键还有 `returns`、`throws`、`examples`、`deprecated`。
- 单个包用 `[coverage.package.<包名>]`，只要求某个语言达到翻译比例用 `[coverage.translation]`。

保存后重新运行 `cjdoc check --project .`。低于门槛时以 `1` 退出，例如 `error: global symbols coverage 50% is below 100%`；包级消息以 `package <包名>` 开头。配置门槛也用于 `generate` 和 `serve`，但不用于从快照重放的 `render`。

## 4. 在 CI 中用退出码判定

在 CI 中直接运行 `cjdoc check --project .`，让非零状态使任务失败：`0` 表示启用的检查通过；`1` 是诊断或门槛失败；`2` 是参数或配置错误。团队希望 warning 也阻止发布时，再加 `--deny-warnings`。

## 5. 一次性 CLI 门槛

不改项目配置时，可以临时要求符号和参数达到某个比例：

```bash
cjdoc check --project . --min-symbol-coverage 90 --min-parameter-coverage 90
```

**预期结果**：诊断之外额外打印一行统计，例如

```text
documentation coverage: symbols 1/1 (100%), parameters 1/1 (100%)
```

CLI 门槛与 `[coverage]` 门槛同时执行，不互相覆盖。它们的分子也不同：`[coverage]` 的符号与参数要有非空文字；CLI 统计是否存在声明文档、是否匹配到参数的 `@param`。因此空的 `@param name` 可能让 CLI 打印 `1/1 (100%)`，同时触发 `[coverage].parameters` 的失败并退出 `1`。给参数补实际说明，而不是压低门槛。

## `--lint-profile off` 下的参数计数

默认的 `standard` 或 `strict` 会把 `@param` 与声明参数匹配。切到 `off` 后，缺注释等诊断不再出现，已写的参数说明也不计入参数覆盖率（页面仍展示正文）。如果要检查参数覆盖率，不要关闭 lint。

## 失败时怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| 门槛失败但字段看起来都有内容 | 核对分母、是否有空字段以及报告的目标包或语言 | 按 `coverage.json` 找低项，再按诊断定位声明 |
| `unknown [coverage] setting` 或 `duplicate quality configuration setting` | 键名拼错，或用了同一指标的多个别名 | 核对[配置参考](../reference/configuration.md)，每个指标只配一次 |
| `coverage thresholds must be in 0..100` | 阈值越界 | 改为 `0..100` 的整数 |
| 写不进报告目录 | 目录不是 cjdoc 管理的输出，或有锁 | 换尚未创建的目录，或按[管理输出](manage-outputs.md)处理 |
| 报告是 `100%`，但说明不够用 | 覆盖率主要检查是否有内容 | 看 `findings`，再[复核 API 说明](review-contracts.md) |

## 下一步

- 编译并运行注释示例：[检查示例](check-examples.md)。
- 核对源码行为和作者承诺：[复核 API 契约](review-contracts.md)。
- 查找完整阈值、包级门槛和规则键：[配置参考](../reference/configuration.md)；报告字段：[产物参考](../reference/artifacts.md)。
