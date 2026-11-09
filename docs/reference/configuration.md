# 配置参考

`cjdoc.toml` 位于被扫描项目根目录（即 `--project` 指向的目录）。配置按功能由各读取器分别解析；`generate`、`check`、`serve` 会在相关步骤读取项目配置，`render` 不重新读取 `cjdoc.toml`，而使用 Doc IR 中捕获的配置与内容。没有配置文件时，各表采用本页列出的默认值。

配置读取不是一个对所有表都同样严格的 TOML 解析器：`[i18n]`、`[lint]`、`[coverage]`、`[highlight]`、`[limits]`、`[metadata]` 及 `[[source.repositories]]` 等严格消费者会拒绝其负责表中的未知键、重复键或非法值；`[docs]`、`[[docs.pages]]`、`[docs.packages]` 对未识别键通常不报错，错误拼写可能被静默忽略。发现页面或阈值没有生效时，先核对键名、表归属和读取命令。

配置错误通常是输入错误（退出码 `2`），不会产出该次文档。质量诊断和未达到门槛属于检查失败（退出码 `1`）。注释中的标签、分组及语言规则不在此重复，见[文档注释参考](doc-comments.md)；质量指标的计数口径见[状态与限制](states-and-limits.md)，示例检查见[检查文档示例](../how-to/check-examples.md)。

## `[docs]`：项目首页与概念文档

只要配置中出现 `[docs]`、`[[docs.pages]]` 或 `[docs.packages]`，就启用概念文档生成：项目首页、每个发现模块的模块页、每个发现包的包页，以及所列自定义页面。概念页与 API 文档一起输出并可被搜索。

| 键 | 用途 | 默认值 | 约束 |
|---|---|---|---|
| `index` | 项目首页 Markdown 源文件 | `docs/index.md` | 项目内安全相对 `.md` 路径；不能绝对、含 `\\`、`..` 或 `:`。 |
| `index-source` | `index` 的别名 | 同 `index` | 两者等价；如果都出现，读取顺序中后设置的值生效。 |

首页路由固定为 `concepts/index.html`。存在所设源文件时读取它；启用概念文档但首页源文件不存在时生成默认项目页。默认模块页源文件为 `docs/modules/<slug>.md`，默认包页为 `docs/packages/<slug>.md`；不存在时分别生成中立的默认说明。`slug` 将名称中的 ASCII 字母、数字以外字符折叠为连字符，跨平台路径不要依赖其他字符原样保留。每个源 Markdown 最多 256 KiB，概念页总数最多 128。

Markdown 路径必须是项目内安全相对路径且以 `.md` 结尾；源文件必须存在，路径不能逃出项目根或经过符号链接。页面标题显式设置 `title` 时使用该值；否则读取源文件中第一个非代码块、非缩进的 `# ` 标题；没有一级标题时用来源路径回退。页面内容写法、章节与 API 绑定见[添加指南](../tutorials/add-guides.md)。

### `[[docs.pages]]`：自定义指南或概念页

每条 `[[docs.pages]]` 声明一页，`source` 必填，`path` 是同义键。

| 键 | 用途 | 默认值 | 约束 |
|---|---|---|---|
| `source` / `path` | Markdown 源文件 | 必填 | 安全相对 `.md` 路径；文件必须存在。 |
| `route` | HTML 路由 | `concepts/guides/<源路径 slug>` | 必须在 `concepts/` 下；不能以 `/` 或 `\\` 开始，不能含 `..`、`:`、`?`、`#` 或控制字符。未写 `.html` 时自动补上。 |
| `title` | 页面标题 | 第一个 Markdown 一级标题；否则来源路径 | 字符串。 |
| `id` | 逻辑页身份 | `route` | 多语言配对用；省略时内部以页面 route 作为 ID。带 `language` 时必须显式提供。 |
| `language` | 该页正文语言 | 输入配置的 `default-language`（若该源文件存在） | 只发布 `zh-CN` 或 `en`；语言别名会归一化为这两个受支持值。 |
| `kind` | 页面类别 | `guide` | 只接受 `guide`、`package`、`project`、`module`；`package` 可参与包概述选择，其他值按对应页面类别显示。 |
| `package` | 关联包名 | 无 | 指定概述页所属包；不替代页面绑定与包身份检查。 |

路由可以在不同语言间复用。同一语言内的重复 `id` 会报 `CJDOC3110` 并跳过重复页；路由冲突会保留可读前缀并加稳定后缀，报告 `CJDOC4060`，实际路由以生成的导航索引为准。页面数量也受上述 128 页总上限约束。

#### `[docs.pages.sections]`：多语言章节锚点

该表紧跟相应 `[[docs.pages]]`，将稳定章节 ID 映射到该页中实际存在的 Markdown 标题锚点：

```toml
[[docs.pages]]
source = "docs/zh-CN/start.md"
route = "concepts/guides/start"
id = "start"
language = "zh-CN"

[docs.pages.sections]
install = "安装"
first-example = "第一个示例"
```

不同语言页用相同逻辑章节 ID、各自标题的实际锚点。值不是原始标题文本：`Installation` 对应 `installation`，`First example` 对应 `first-example`；本例中文标题的锚点与标题相同。空白转为 `-`，ASCII 大写转为小写；重复或冲突的锚点追加 `-1`、`-2` 等后缀。也接受页面中完整的 `standalone--doc-…` 标题 ID；应以生成页的实际链接为准，不凭标题猜测后缀。

锚点不存在、逻辑章节 ID 重复，或不同映射解析到同一个实际标题锚点时，相关映射被忽略并报告 `CJDOC3110` warning；页面其余内容仍生成。重复标题本身可以通过各自不同的实际锚点分别映射。章节键和值都按字符串读取；稳定键由作者维护。

### `[docs.packages]`：包概述源文件

简写表每个包一项，或使用包子表；两种写法都指定项目内相对 Markdown 路径：

```toml
[docs.packages]
pocketkit = "docs/pocketkit.md"

[docs.packages."pocketkit-core"]
overview = "docs/pocketkit-core.md"
```

`[docs.packages]` 的值是路径；`[docs.packages.<包名>]` 接受 `source`、`path`、`overview` 三个同义键。带点的包名应使用子表。包名不得是绝对路径或含 `\\`、`..`、`:`。没有对应已发现包的配置项不会生成额外包。

未配置源文件时，默认读取 `docs/packages/<slug>.md`；该文件缺失时保留中立默认包页。显式指定的概述文件缺失则按概念页来源错误处理。包概述是否显示在 HTML 包页顶部，还要求正文非空、绑定全部可解析且能唯一证明所属模块；同一个 Markdown 文件不会重复出现。`kind = "package"` 的页面优先于普通指南候选。具体页面写法见[添加指南](../tutorials/add-guides.md)。

## `[[source.repositories]]`：显式多仓源码来源

用于 workspace 或混合源码树中按源码根登记 GitHub 仓库，并通过调用方固定的 receipt 校对本次读取的源码字节。这不是 Git commit、远端、工作树或构建状态的独立认证。配置文件最多 64 KiB，最多 4096 条登记。

```toml
[[source.repositories]]
root = "packages/core/src"
url = "https://github.com/example/core"
revision = "<完整 40 位小写 commit SHA>"
repository-path = "src"
receipt = "evidence/core-source.json"
receipt-sha256 = "<receipt 原始字节的 64 位小写 SHA-256>"
```

上例是字段形状说明，不可直接执行：仓库、commit、receipt 路径与两个摘要必须替换成真实、相互一致并由调用方信任的信息。

| 键 | 必需 | 含义与规则 |
|---|---|---|
| `root` | 是 | 被登记的本地目录或单个源码文件；相对配置所在项目根或绝对路径。必须存在，不能是符号链接。仅用于生成，不写入公开 Doc IR。 |
| `url` | 是 | 规范 GitHub HTTPS 仓库根 `https://github.com/<owner>/<repo>`。 |
| `revision` | 是 | 完整 40 位小写十六进制 commit SHA。此要求针对显式多仓登记；旧 `--repository-revision` 单仓选项另保留其原 ref 行为。 |
| `repository-path` | 否 | 仓库内安全相对路径前缀，默认空。目录 root 时与相对文件路径组合；单文件 root 时必须提供该文件完整仓内路径。 |
| `receipt` | 否 | `cjdoc.source-provenance/1` JSON 文件路径，相对项目根或绝对路径。 |
| `receipt-sha256` | 否 | receipt 文件精确原始字节的 64 位小写 SHA-256；必须与 `receipt` 成对提供才可能得到 `verified`。 |

每条 receipt 必须只有 `schemaVersion`、`repository`、`files`：`schemaVersion` 为 `cjdoc.source-provenance/1`；`repository` 含 `url` 与 `revision`；每个 `files` 条目含唯一、安全的仓内 `path` 与原始字节 SHA-256。未知/重复 JSON 键、额外字段、不安全路径或格式错误均拒绝。可通过 `cjdoc schema source-provenance` 查看协议结构。

receipt 本身的 pin 必须来自独立可信渠道，并覆盖 receipt 精确字节；仅重排 JSON 或改换行就会改变 pin。receipt 的文件摘要校对捕获源码原始字节；Doc IR 另外记录将 CRLF/CR 归一为 LF 后的摘要。`verified` 仅表示仓库登记与调用方 pin 的 receipt 一致，且被捕获文件的原始字节摘要匹配。它不证明 Git object、构建、远端或工作树状态。

只要配置了任意一条登记，就进入严格登记模式：未匹配文件不会回退到主仓或 `--repository-url`；重叠登记映射冲突时状态为 `ambiguous`，不按前缀长度或顺序猜测。receipt 缺失、未 pin、仓库信息不符或文件摘要不符时来源为 `unavailable`，报告 `CJDOC1032` 并省略源码链接，API 内容仍保留。未登记文件也报告 `CJDOC1032`。旧单仓 URL/revision 映射标为 `declared`，不是字节校验结论。渲染已捕获的 Doc IR 时不重新读取源码或 receipt。可读状态定义见[状态与限制](states-and-limits.md)，实用操作见[链接外部文档](../how-to/link-documentation.md)。

## `[metadata]`：声明分组与标签标题

元数据配置按发现的 module 读取：每个模块自己的项目根目录读取其 `cjdoc.toml`；同一实际根的解析结果可复用，但绑定仍按 module ID 区分。workspace 根配置不会自动传给成员项目或依赖。每个配置最多 64 KiB；group 和 tag 各最多 2048 条。

```toml
[[metadata.groups]]
package = "pocketkit"
owner = "pocketkit.TextCatalog" # 或使用 owner-id，不可同时填写
id = "20-query"
title = "查询"
order = 20

[metadata.groups.titles]
en = "Query"

[[metadata.tags]]
id = "streaming"
title = "流式"

[metadata.tags.titles]
en = "Streaming"
```

`[[metadata.groups]]` 必须有 `package`、`id`、`title`；`owner`、`owner-id`、`order` 可选。省略 owner 表示包级组。`owner` 必须是同包完整限定名；`owner-id` 必须是同 module/package 的完整 SymbolId；只接受 class、struct、interface、enum、extend 作为 owner。`owner` 与 `owner-id` 互斥。`order` 为 `0..999999` 整数；有显式 order 的组按顺序排列，未指定者排在后面。

`[[metadata.tags]]` 只接受必填 `id` 和 `title`，不接受 package、owner 或 order。标签定义只提供显示标题，不添加成员关系；每个声明仍须显式写 `@tag <id>`。定义标题可以被正文未定义的 ID 替代，未定义 tag 仍以 ID 显示；反之，无标题的 `@group <id>` 简写只有匹配的集中 group 定义才生效。分组和标签的完整语义、诊断见[文档注释参考](doc-comments.md#分组与标签)。

Group/tag ID 均为 1–64 个 ASCII 字母、数字、`-`、`_`。基础标题及每种语言译名为 1–256 UTF-8 字节的单行纯文本；不得全为空白或含 C0/DEL 控制字符。`[metadata.groups.titles]`、`[metadata.tags.titles]` 每条定义最多写 `zh-CN`、`en` 两个译名；标题显示优先级为当前语言译名、基础标题、（仅 group）合法内联标题、ID。标题不影响成员身份、搜索 ID、SymbolId、API fingerprint 或翻译覆盖率。

配置只能使用 `[[metadata.groups]]`、`[[metadata.tags]]` 及各条对应的 `titles` 子表；可选 `[metadata]` 必须为空。未知表/键、重复键、dotted/inline 变体、类型错误或越界值报 `CJDOC3133`，严格失败，退出码 `2`。解析成功但绑定失败会保留诊断并使文档为 partial：`CJDOC3134` package/owner 不存在，`CJDOC3135` owner 有歧义，`CJDOC3136` 同 scope 定义重复且竞争项都无效，`CJDOC3137` 无匹配定义的无标题 `@group` 简写。隐藏声明可绑定为 owner，但只捕获发布投影中实际使用的定义。

## `[limits]`：Doc IR JSON 大小

| 键 | 取值 | 默认值 |
|---|---:|---:|
| `max-doc-ir-mib` | 整数 `1..64` MiB | `64` |

```toml
[limits]
max-doc-ir-mib = 32
```

必须使用单个 `[limits]` 表。顶层 dotted key `limits.max-doc-ir-mib`、inline table、`[[limits]]` 或子表均不支持。配置文件中重复键、未知键或非法值即使同时有 CLI 覆盖仍是错误。`generate`、`check`、`serve` 的 `--max-doc-ir-mib` 覆盖有效配置值；`render` 不读取项目配置，使用默认值或自己的 CLI 选项。输入文件预算按包含空白的原始输入字节计；生成阶段按编码大小保守计量。输入超过预算返回输入错误；生成超限保留有界回退并报告 `CJDOC3027` warning，`check --deny-warnings` 会使 warning 失败。64 MiB 是硬上限；单字符串、产物、对象数量和递归深度仍受各自限制。资源限制与诊断见[状态与限制](states-and-limits.md)。

## `[i18n]`：发布语言

| 键 | 取值 | 默认值 | 规则 |
|---|---|---|---|
| `default-language` | `zh-CN` 或 `en` | 无 | 出现 `[i18n]` 时必填，否则 `CJDOC3105`。 |
| `languages` | 字符串数组，最多两项 | 仅 default-language | 只能列 `zh-CN`、`en`，不可重复或为空；若省略，只发布默认语言。 |
| `missing-translation` | `warn` 或 `deny` | `warn` | `deny` 将缺译诊断升级为 error。 |

```toml
[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"
```

`[i18n]` 表启用完整注释本地化；语言、条目配对、提示专用范围、缺译回退及覆盖率定义见[文档注释参考](doc-comments.md#多语言注释)与[发布多语言页面](../tutorials/publish-languages.md)。语言列表不做 `zh-Hans`、`zh-TW`、`en-US` 等区域别名推断。

## `[lint]`：质量规则严重级别

`severity` 默认 `warning`，允许 `off`、`warning`、`error`。各项可单独覆盖；未单独设置时跟随 `severity`，唯一例外是 `example-not-compiling` 默认 `error`。

| 键 | 检查内容 |
|---|---|
| `missing-summary` | 符号缺少摘要。 |
| `missing-symbol-doc` | 可见符号完全没有注释。 |
| `missing-param` | 参数缺少对应 `@param`。 |
| `missing-return` | 有非 Unit 返回值的声明缺 `@return`。 |
| `missing-throws` | `@throws` 没有说明。 |
| `missing-example` | 符号缺少 `@example`。 |
| `empty-description` | 有摘要但没有详细说明。 |
| `broken-link` | `@see` 等引用目标不存在。 |
| `ambiguous-link` | 引用目标无法唯一解析。 |
| `unresolved-type-link` | 类型或语义引用无法解析。 |
| `invalid-since-version` | `@since` 不是 2–4 段数字。 |
| `deprecated-without-message` | `@deprecated` 缺弃用说明。 |
| `duplicate-param` | 同参数有多个 `@param`。 |
| `duplicate-return` | 有多个 `@return`。 |
| `duplicate-throws` | 同一异常有多个 `@throws`。 |
| `example-not-compiling` | 示例编译失败（`CJDOC3030`）。 |

```toml
[lint]
severity = "warning"
missing-example = "off"
broken-link = "error"
example-not-compiling = "error"
```

`--lint-profile off` 关闭 lint；`standard`（默认）与 `strict` 启用相应规则集合和严重级别。`--deny-warnings` 把 warning 也作为失败。`coverage` 输出包括 `coverage/quality.json`，其中记录质量发现。检查策略与错误码见[检查文档质量](../how-to/check-quality.md)。

## `[coverage]`：覆盖率门槛

所有门槛是 `0..100` 整数；未设门槛不检查。它们与 `coverage/coverage.json` 报告所展示的指标同属报告统计，但报告百分比、CLI 临时符号/参数门槛及翻译覆盖率分母不是一个互换计数，详见[状态与限制](states-and-limits.md#覆盖率与质量统计)。

| `[coverage]` 键 | 计数对象 |
|---|---|
| `symbols` | 可见声明中有非空摘要的比例。 |
| `parameters` | 可见非 `_` 开头参数中有非空说明的比例。 |
| `returns` | 有非 Unit 返回值声明中有非空 `@return` 的比例。 |
| `throws` | 实际记录的 `@throws` 条目中有非空说明的比例。 |
| `examples` | 可见声明中至少有非空 `@example` 的比例；无注释声明仍计入分母。 |
| `deprecated` | 实际记录的 `@deprecated` 条目中有非空弃用说明的比例。 |
| `semantic-links` | 已记录语义链接中解析成功的比例。 |

兼容的单数别名：`symbol`、`parameter`、`return`、`throws-docs`、`example`、`semantic-link`。重复定义任一标准键或别名仍为重复配置错误。

`generate`、`check` 执行配置门槛，`render` 不执行。`check --min-symbol-coverage` 与 `--min-parameter-coverage` 是额外的一次性门槛，与配置门槛同时检查，不覆盖配置。低于阈值报 error 并退出 `1`；指标分母为 0 时按 100% 计算。

### `[coverage.package.<包名>]` 与 `[coverage.translation]`

包级门槛覆盖与 `[coverage]` 相同的指标集合；只对该包显式设置的指标覆盖全局值，其余继承全局阈值。包名必须匹配本次选择受众下的包，否则报错并失败：

```toml
[coverage]
symbols = 90
parameters = 95

[coverage.package.basic]
symbols = 100

[coverage.translation]
en = 90
```

`[coverage.translation]` 用 `zh-CN` 或 `en` 为每个语言设置 `0..100` 最低翻译覆盖率。低于阈值报 `CJDOC3111` 并退出 `1`；`cjdoc check --require-language en` 等价于要求该语言达到 100%，可重复指定。`--locale` 仅选择阅读视图，不会绕过其他已发布语言的缺译检查。

## `[highlight]`：代码高亮

| 键 | 可选值 | 默认值 | 规则 |
|---|---|---|---|
| `mode` | `static`、`off` | `static` | `off` 时所有代码块纯文本。 |
| `languages` | 非空字符串数组 | `["cangjie"]` | 归一化后不可为空或重复；未列语言不高亮。 |
| `on-error` | `warn`、`error` | `warn` | 失败时保留纯文本并报告 `CJDOC3120` warning，或报告 `CJDOC4027` error。 |

```toml
[highlight]
mode = "static"
languages = ["cangjie", "json"]
on-error = "warn"
```

内置高亮只支持仓颉。`json`、`bash`、`python`、`toml`、`yaml` 需要通过外部适配器；列入 `languages` 并不会授权执行外部程序。外部后端必须同时提供 `--highlight-adapter` 与 `--highlight-node`，两者都需要绝对路径，且仅用于 `generate`、`check`。未配置后端时这些语言保持纯文本并可能报告 warning。详细准备步骤见[代码高亮](../how-to/highlighting.md)。

## `[external-docs.<名称>]`：旧式显式外部文档配置

这是旧项目的兼容表，只提供显式参考链接，不参与依赖自动匹配；新接入请使用文档目录/库存参数，见[链接外部文档](../how-to/link-documentation.md)。

| 键 | 含义 | 默认值 |
|---|---|---|
| `index` | 项目内相对或绝对的外部文档索引文件路径 | 无 |
| `base-url` | `https://` 地址或以 `./` 开始的相对文档根地址 | 无 |
| `version` | 展示的文档版本文字 | 无 |

```toml
[external-docs.support]
index = "docs/support-index.json"
base-url = "https://docs.example.test/support"
version = "2.1"
```

这组表由兼容消费者读取；不要把 `index` 解释成自动匹配依赖的证明，也不要在此提供凭空声明的 verified 状态。

## 已移除的 `[doctest]`

`[doctest]` 不再支持；出现该表会直接报配置错误。示例执行现在通过 `@example` 指令和显式 `--check-examples` 启用，见[文档注释参考](doc-comments.md#示例)和[检查文档示例](../how-to/check-examples.md)。

## 配置组合示例

下面汇总常见配置形状。它只声明项目配置，不代替对应的 Markdown 页面、真实 receipt 或注释内容；按项目实际需要删减。

```toml
[docs]
index = "docs/index.md"

[[docs.pages]]
source = "docs/zh-CN/start.md"
route = "concepts/guides/start"
id = "start"
language = "zh-CN"
kind = "guide"

[docs.pages.sections]
install = "安装"
first-example = "第一个示例"

[[docs.pages]]
source = "docs/en/start.md"
route = "concepts/guides/start"
id = "start"
language = "en"
kind = "guide"

[docs.pages.sections]
install = "installation"
first-example = "first-example"

[docs.packages]
pocketkit = "docs/pocketkit.md"

[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"

[lint]
severity = "warning"
missing-example = "off"
broken-link = "error"

[coverage]
symbols = 90
parameters = 95

[coverage.package.basic]
symbols = 100

[coverage.translation]
en = 90

[highlight]
mode = "static"
languages = ["cangjie"]
on-error = "warn"

[limits]
max-doc-ir-mib = 64
```

配置变更的完整操作流程见[添加指南](../tutorials/add-guides.md)、[发布多语言页面](../tutorials/publish-languages.md)、[检查文档质量](../how-to/check-quality.md)与[代码高亮](../how-to/highlighting.md)。