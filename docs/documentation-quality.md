# 检查文档质量

文档质量分为三个显式层次，不能用前两层代替第三层：

| 层次 | 当前证据 | 能回答什么 | 不能据此宣称 |
|---|---|---|---|
| 存在性 | `coverage.json` | 说明字段是否有内容 | 内容正确、充分 |
| 非模板/结构质量 | `quality.json`、quality/lint | 是否命中已定义的模板或结构规则 | `meaningful` 等于行为正确 |
| 语义充分性与一致性 | [作者侧契约复核](contract-review.md) | 作者声明、源码行为和实际运行覆盖是否一致；哪些边界仍未知 | 单个示例通过或零诊断等于完整契约证明 |

前两层是现有自动报告；第三层使用有来源、带正反例的人工 checklist，不新增自动语义评分或从 API 名称推断异常、同步、复杂度。

这类报告能回答：

- 当前受众可见的符号里，哪些没有摘要、参数说明、返回值说明、异常说明、示例或弃用说明；
- 哪些摘要、参数说明、返回值说明只是重复了声明名或类型名；
- 按包、模块看，哪一部分最薄弱。

这类报告不能回答：

- 注释内容是否正确、完整、易读，这需要人工评审；
- 译文是否齐全，这看[多语言文档](i18n.md)里的翻译覆盖率；
- 示例能否编译或运行，这要用 `cjdoc check --check-examples`（示例自身编译失败报 `CJDOC3030`）；
- 文档是否达到发布标准，阈值由你设置并接入 CI。

## 生成报告

在项目根目录运行：

```bash
cjdoc generate --project . --format coverage
```

默认输出到 `target/doc`，得到两个文件：

```text
target/doc/coverage/coverage.json
target/doc/coverage/quality.json
```

启用 `[i18n]` 时，同一目录还会写出 `coverage/translations.json`，见[多语言文档](i18n.md)。

`--stdout` 可以把报告直接交给管道，但只输出存在覆盖率这一份：

```bash
cjdoc generate --project . --format coverage --stdout > coverage.json
```

`quality.json` 和 `translations.json` 只在目录输出时生成。

报告统计 `--audience` 指定的受众，默认是 `external`（只统计公开和受保护声明）。需要看全部声明时：

```bash
cjdoc generate --project . --format coverage --audience all
```

## 区分两种报告

| | `coverage.json` | `quality.json` |
|---|---|---|
| 回答的问题 | 字段里有没有内容 | 摘要和参数说明是不是模板占位 |
| 计数名 | `documented` | `meaningful` |
| 覆盖范围 | 七类指标，并按 package、module 分组 | 只有 symbols、parameters 两个百分比，加上 findings 明细 |
| 能否设门槛 | 能，见[设置会失败的门槛](#设置会失败的门槛) | 不能，只用于报告和看板 |

`quality.json` 的内容类似：

```json
{
  "audience": "external",
  "symbols": { "total": 42, "meaningful": 31, "percent": 73 },
  "parameters": { "total": 96, "meaningful": 70, "percent": 72 },
  "findings": [
    { "symbolId": "...", "code": "CJDOC3047", "message": "trivial-summary: ..." },
    { "symbolId": "...", "code": "CJDOC3048", "message": "trivial-param-description: ..." }
  ]
}
```

含义如下：

- `symbols.total` 是当前受众可见的符号数，`symbols.meaningful` 是其中摘要非空、且没有命中 `CJDOC3047` 的符号数。
- `parameters.total` 是不以 `_` 开头的参数数，`parameters.meaningful` 是其中参数说明非空、且没有命中 `CJDOC3048` 的参数数。
- `findings`：三条模板规则的命中明细。返回值命中（`CJDOC3049`）也会列在这里，但它不扣 symbols、parameters 的百分比。
- 百分比向下取整；分母为 0 时记为 100。
- 完全没有文字的注释不计入 `meaningful`，也不会命中模板规则，因为没有文字可判为模板。

## 读懂七类指标

`coverage.json` 的 `metrics` 里有七类指标，每类都是 `total`、`documented`、`percent`：

| 指标 | 分母 | 记为已记录（documented） |
|---|---|---|
| `symbols` | 当前受众可见的符号 | 第一段摘要非空 |
| `parameters` | 可见符号的参数（名字以 `_` 开头的除外） | 参数说明非空 |
| `returns` | 有返回值（返回类型不是 `Unit`）的可见符号 | `@return` 说明非空 |
| `throws` | `@throws` 条目 | 该条说明非空 |
| `examples` | 可见符号数（每个符号只计一次，不按示例个数累计） | 该符号至少有一个非空 `@example` |
| `deprecated` | `@deprecated` 条目 | 弃用说明非空 |
| `semanticLinks` | `@see` 条目加上正文里的语义链接 | 引用唯一解析成功 |

摘要只取 Markdown 的第一个正文段落。`coverage.json` 还会给出 `packages`、`modules` 两组同样的指标，便于按包定位薄弱区域；[设置会失败的门槛](#设置会失败的门槛)可以用这些分组按包设置不同要求。

## 识别三条模板规则

生成和检查时，`--lint-profile standard`（默认）和 `strict` 都会报告三条模板规则：

| 诊断码 | 规则 | 判为模板的条件 | 典型命中 |
|---|---|---|---|
| `CJDOC3047` | trivial-summary | 摘要只有声明名，可带 `API`、`公开 API`、`<项目名> 公开 API`、`<项目名> API` 前缀 | `add`、`API：add`、`<项目名> 公开 API：add` |
| `CJDOC3048` | trivial-param-description | 参数说明只有参数名，可带 `参数`、`parameter`、`param` 前缀 | `参数 left。`、`parameter left` |
| `CJDOC3049` | trivial-return-description | 返回值说明只有返回类型，可带 `返回`、`return`、`returns` 前缀 | 返回类型是 `Int64` 时写 `返回 Int64。` |

匹配时只做保守判断：

- 忽略 ASCII 空白、大小写、句号、冒号和行内代码标记，并要求整段文字匹配，所以“参数 value 必须是正数。”不会被误判。
- 摘要只看第一个正文段落。
- 名字以 `_` 开头的参数跳过参数规则。
- 项目名前缀必须和当前项目名一致。
- 规则按 `--audience` 的可见范围检查。

**未命中不代表写得好。** 下面的注释不命中任何模板规则，但对读者没有信息量：

```cangjie
/**
 * 处理数据。
 * @param value 输入。
 * @return 结果。
 */
public func normalize(value: Int64): Int64 { value }
```

三条模板规则只能由 `--lint-profile` 整组开关，不能用 `[lint]` 逐条关闭；`--lint-profile off` 会关闭常规 lint（包括这三条诊断），但不会阻止 `quality.json` 计算质量分，也不会关闭 `--check-examples` 启用的示例编译诊断。`[lint]` 配置的严重级别适用于下一节列出的规则，示例编译有独立的默认级别。

## 设置会失败的门槛

### 用配置设置覆盖率和按包门槛

在项目根目录的 `cjdoc.toml` 里写：

```toml
[coverage]
symbols = 80
parameters = 90
returns = 70

[coverage.package.my_package]
symbols = 95
parameters = 95
```

规则：

- 七类指标都可以设门槛：`symbols`、`parameters`、`returns`、`throws`、`examples`、`deprecated`、`semantic-links`。取值 0..100。
- 门槛在 `generate` 和 `check`（以及 `serve` 的预览构建）中执行，`render` 不执行。低于门槛会打印 `error: ... coverage ...% is below ...%`，退出码为 1。
- `[coverage.package.<包名>]` 只覆盖显式写出的指标，没写的继续沿用全局设置。包名必须能匹配当前项目中的包，否则报错。
- 门槛基于 `coverage.json` 的口径：要求字段内容非空，不看 `quality.json` 的 `meaningful`。

### 用命令行加一次性门槛

```bash
cjdoc check --project . \
  --min-symbol-coverage 80 \
  --min-parameter-coverage 90
```

这两个选项取 0..100，只在显式传入时检查。它们统计的是“声明或参数有没有绑定文档注释”，比 `coverage.json` 的口径更宽：例如一个只有空摘要的符号也会被算作已记录。

### 调整 lint 严重级别

在 `cjdoc.toml` 中：

```toml
[lint]
severity = "warning"
missing-param = "error"
missing-example = "off"
```

- `severity` 是常规 lint 的默认级别，可被每条规则的设置覆盖；取值 `off`、`warning`、`error`。
- 常规 lint 只在 `--lint-profile` 不是 `off` 时运行；`--check-examples` 启用的示例编译不受此开关影响。
- 可配置的规则键：
  - 缺失类：`missing-symbol-doc`、`missing-summary`、`missing-param`、`missing-return`、`missing-throws`、`missing-example`、`empty-description`
  - 引用类：`broken-link`、`ambiguous-link`、`unresolved-type-link`
  - 元数据类：`invalid-since-version`、`deprecated-without-message`
  - 重复类：`duplicate-param`、`duplicate-return`、`duplicate-throws`
  - 示例类：`example-not-compiling` 控制归因到示例文件的编译失败 `CJDOC3030`，只在 `--check-examples` 时生效，默认按 error 处理，不继承 `severity`；即使 `--lint-profile off` 仍会报告，可显式设为 `off` 关闭该诊断。未归因到示例文件的编译失败 `CJDOC3031` 仍按 error 报告。
- 把关键规则改成 `error` 后，`cjdoc check` 会在命中时以退出码 1 失败。`--deny-warnings` 则把当前所有 warning 一并视为失败，适合发布前收紧。

退出码：

| 退出码 | 含义 |
|---:|---|
| 0 | 没有被当前规则拒绝的诊断 |
| 1 | 存在 error，或覆盖率门槛未通过，或 warning 被 `--deny-warnings` 提升 |
| 2 | CLI 参数或配置错误 |

## 改进注释

模板规则只识别“只重复名字”的写法。真正有用的注释通常补充三类信息：这段代码做什么、参数有什么约束、返回值代表什么。

反例（同时命中三条模板规则，且 `right` 参数没有说明）：

```cangjie
/**
 * add
 * @param left 参数 left。
 * @param right
 * @return 返回 Int64。
 */
public func add(left: Int64, right: Int64): Int64 { left + right }
```

正例：

~~~cangjie
/**
 * 计算两个整数的和。
 *
 * 按 64 位有符号整数直接相加，溢出行为由编译器选项决定。
 *
 * @param left 被加数。
 * @param right 加数。
 * @return 两个参数之和。
 * @example 基本用法
 * ```cangjie
 * let sum = add(1, 2)
 * ```
 */
public func add(left: Int64, right: Int64): Int64 { left + right }
~~~

改进后的注释在 `coverage.json` 里会依次把摘要、参数、返回值都记为已记录，也不再命中 `CJDOC3047`、`CJDOC3048`、`CJDOC3049`。示例部分还可以用 `cjdoc check --check-examples` 验证能否编译。

## 接入 CI

最小做法是在 CI 中对项目跑一次 `check`，用退出码决定是否失败；需要保存报告时再生成 `coverage` 目录：

```bash
# 存在 error、门槛不通过或（配合 --deny-warnings）warning 时退出码为 1
cjdoc check --project . --min-symbol-coverage 80 --min-parameter-coverage 90

# 保存报告作为 CI 产物
cjdoc generate --project . --format coverage --output target/quality-report
```

`[coverage]`、`[coverage.package.*]` 中配置的门槛由 `check` 和 `generate`（以及 `serve` 的预览构建）自动执行，不必在命令行重复。`quality.json` 没有独立门槛，如果要看趋势，把它作为 CI 产物归档即可。

## HTML 展示与限制

`cjdoc generate --project . --format html` 生成的站点在存在诊断时，首页底部会有一个可展开的“构建状态与诊断”区域，列出当前受众可见符号相关的诊断；lint 开启时，`CJDOC3047`、`CJDOC3048`、`CJDOC3049` 会出现在这里，并带上级别、诊断码、消息和源码位置。`html/validation.html` 只汇总“诊断: N”这类数量，不逐条列出规则。API 页面本身不显示质量分或质量徽标，质量分只存在于 `coverage/quality.json`，避免把启发式评分展示给读者。

限制：

- 质量分是启发式计数，只覆盖三条已知模板规则，不是人工评审分数。
- 存在覆盖率只说明“有内容”，不说明内容正确；模板规则未命中也不说明写得好。
- 启用多语言时，`coverage.json` 与 `quality.json` 按默认语言（`[i18n].default-language`）的注释视图统计；译文完整度看 `coverage/translations.json`。
- 质量分没有阈值配置；需要更严格的门槛时，用存在覆盖率门槛加 `[lint]` 严重级别。
- 示例是否可用需要显式 `--check-examples`，普通生成或检查不会编译示例。

## 下一步

- 了解注释标签与示例指令：[常用用法](usage.md)
- 把覆盖率、API 快照等接入 CI：[高级用法](advanced-usage.md)
- 需要中英文两种语言时：[多语言文档](i18n.md)

维护者内容（CI 编排、报告内部格式等）见 [`docs/maintainer/`](https://github.com/lIlIIlIll/cjdoc/tree/main/docs/maintainer)。
