# 配置参考

项目根目录的 `cjdoc.toml` 用到的每个表与键。`generate`、`check`、`serve` 在读取项目的阶段解析它；`render`、`diff`、`query`、`mcp`、`schema`、`versions compose` 不读配置文件——`render` 使用 Doc IR 中已捕获的设置，离线重放因此不受项目配置影响。文件缺失时各表采用本页列出的默认值。

`cjdoc.toml` 按整个文件校验，不只是被用到的表：未知表、未知键、重复键和非法取值都报错，即使同一条命令用 CLI 覆盖了该设置也一样。只有一层配置——项目根的 `cjdoc.toml`，没有第二个配置文件、没有继承、没有全局配置。**相对路径按项目根解析**，与在哪个目录调用 `cjdoc` 无关；`--project` 改变项目根，因此也改变这些路径的基准。

配置错误是输入错误，退出码 `2`，不产出该次文档；质量诊断与未达标门槛是检查失败，退出码 `1`。操作的下一步见[添加指南](../tutorials/add-guides.md)、[发布多语言页面](../tutorials/publish-languages.md)、[检查文档质量](../how-to/check-quality.md)、[代码高亮](../how-to/highlighting.md)、[链接外部文档](../how-to/link-documentation.md)。

## 快速索引

| 你要设置 | 表 | 关键约束 |
|---|---|---|
| 产物目录与格式 | `[output]` | 至少一种格式；仅 generate/serve |
| 受众、并发、规则档、依赖、缓存 | `[analysis]` | `jobs` 为 `1..64`；`cache-dir` 与 `no-cache` 互斥 |
| 语义模式 | `[semantic]` | `source` 或 `chir`，默认 `chir` |
| 首页、指南、包概述 | `[docs]`、`[[docs.pages]]`、`[docs.pages.sections]`、`[docs.packages]` | 路由必须在 `concepts/` 下 |
| 分组与分类标签标题 | `[metadata]`、`[[metadata.groups]]`、`[[metadata.tags]]` | 标题只影响显示 |
| 发布语言 | `[i18n]` | 只需 `default-language`；最多两种语言 |
| 质量规则严重级别 | `[lint]` | 规则可单独关闭或升级 |
| 覆盖率门槛 | `[coverage]` 及包级、翻译门槛 | `0..100` 整数 |
| 代码高亮 | `[highlight]` | 内置只支持仓颉 |
| Doc IR 大小 | `[limits]` | `1..64` MiB |
| 多仓源码来源 | `[[source.repositories]]` | 必须完整 commit SHA |
| 旧式外部文档链接 | `[external-docs.<名称>]` | 不产生 `verified` |
| 已移除的示例执行配置 | `[doctest]` | 出现即报错 |

## 表索引

| 表 | 作用 |
|---|---|
| `[output]` | 输出目录、格式、agent 树与 HTML 字体，作用于 generate、serve |
| `[analysis]` | 受众、并发、规则档、依赖选择与缓存 |
| `[semantic]` | 语义模式（`source` 或 `chir`） |
| `[docs]`、`[[docs.pages]]`、`[docs.pages.sections]`、`[docs.packages]` | 概念文档：首页、指南、包概述 |
| `[metadata]`、`[[metadata.groups]]`、`[[metadata.tags]]` 及其 `titles` 子表 | 分组与分类标签的集中标题 |
| `[i18n]` | 发布语言与缺译策略 |
| `[lint]` | 质量规则严重级别 |
| `[coverage]`、`[coverage.package.<包名>]`、`[coverage.translation]` | 覆盖率门槛 |
| `[highlight]` | 代码高亮策略 |
| `[limits]` | Doc IR JSON 大小上限 |
| `[[source.repositories]]` | 多仓源码来源登记与 receipt 校对 |
| `[external-docs.<名称>]` | 旧式显式外部文档链接 |
| `[doctest]` | 已移除，出现即报错 |

`[output]`、`[analysis]`、`[semantic]` 是命令行默认值的项目侧写法，下一节说明它们和 CLI 的优先级；其余各表是既有策略，语义不变。

## 常用命令行默认值：`[output]`、`[analysis]` 与 `[semantic]`

这三张表把日常使用的命令行选项写进项目，让 `cjdoc generate`、`cjdoc check`、`cjdoc serve` 不带参数也能按项目约定运行。它们只提供默认值：同一条命令里显式给出的 CLI 值总是覆盖配置，而配置本身仍按上文的规则完整校验。

这些表的字符串值使用单行双引号或单引号；三引号多行字符串不受支持，出现时会报配置错误，不会当作省略该设置。数组可以跨行书写，但每个字符串元素仍须使用单行引号。

### `[output]`：产物目录与格式

只作用于 `generate` 与 `serve`；`check` 运行诊断却从不写站点，因此忽略整张表，不会因为配置了 `[output]` 就在检查时要求 HTML 或创建目录。

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `formats` | `json`、`markdown`、`html`、`api-surface`、`coverage`、`symbol-index` 的数组 | `["json"]` | 至少一项，不能重复；输出顺序固定，与书写顺序无关 |
| `directory` | 目录 | generate/serve 为 `<项目>/target/doc` | 相对路径按项目根解析；不能与源码缓存目录重叠或嵌套 |
| `agent-full` | `true`、`false` | `false` | 需要 HTML 输出 |
| `html-font-sans` | 字体族列表字符串 | 无 | 与 `--html-font-sans` 同规则，需要 HTML 输出 |
| `html-font-mono` | 字体族列表字符串 | 无 | 与 `--html-font-mono` 同规则，需要 HTML 输出 |

```toml
[output]
formats = ["html", "json"]
directory = "target/site"
agent-full = true
```

- 命令行给出 `--format` 时，这份列表**替换**配置，而不是合并：`--format json` 只产出 `json`。
- `agent-full` 与两个字体键只对 HTML 产物生效：解析后的格式不含 `html`（或命令是 check/`--stdout`）时它们不会被继承，也不会因此报错；配置写错仍在读取时立即报错。命令行显式给出这几项却只要 `json` 时依旧报错。
- `--output` 覆盖 `directory`；`--stdout` 是一次性的单向输出，此时 `[output]` 整张表都不参与。
- 关闭型开关可以用 `--no-agent-full` 在单次命令中反转配置。
- `formats` 写成非数组字面量、空数组或重复项都报配置错误。

### `[analysis]`：受众、并发、依赖与缓存

| 键 | 取值 | 对应选项 |
|---|---|---|
| `audience` | `external`、`package`、`all` | `--audience` |
| `jobs` | `1..64` | `--jobs` |
| `lint-profile` | `off`、`standard`、`strict` | `--lint-profile` |
| `include-path-dependencies` | `true`、`false` | `--include-path-dependencies`、`--no-include-path-dependencies` |
| `include-cached-dependencies` | `true`、`false` | `--include-cached-dependencies`、`--no-include-cached-dependencies` |
| `cjpm-cache` | 目录 | `--cjpm-cache`，仅在缓存依赖打开时采用 |
| `cache-dir` | 目录 | `--cache-dir` |
| `no-cache` | `true`、`false` | `--no-cache` |
| `cfg` | `NAME=VALUE` 数组 | `--cfg` |
| `dependency-sources` | `NAME=PATH` 数组 | `--dependency-source` |

```toml
[analysis]
audience = "package"
jobs = 4
lint-profile = "standard"
cfg = ["feature=extra"]
dependency-sources = ["support=vendor/support"]
cache-dir = "target/cjdoc-cache"
```

- `cache-dir` 与 `no-cache = true` 互斥，同时出现是配置错误 `[analysis] cache-dir and no-cache are mutually exclusive`；命令行里 `--cache-dir`、`--no-cache`、`--cache` 按最后出现的那个生效，所以配置关闭缓存后仍可用 `--cache` 在单次命令中重新打开。
- `cfg` 与 `dependency-sources` 按名称合并：CLI 给出同名项时使用 CLI 的值，其余配置项继续生效。`dependency-sources` 的路径同样按项目根解析，同名项在配置内重复是错误。
- `cfg` 只影响文档的条件选择，不会自动补上 `os`、`arch`、`debug` 的宿主值；内建选择器写非宿主值时文档照常生成，但同一次 `--check-examples` 会因与真实编译目标不一致而失败。见[选择输入与依赖](../how-to/select-inputs.md)。
- `dependency-sources` 是对依赖源码的显式选取；`include-path-dependencies` 只控制其余 manifest 路径依赖的自动收集。`--no-include-path-dependencies` 不移除已显式选取的依赖，需要替换路径时用同名 `--dependency-source`。
- `cjpm-cache` 只在 `include-cached-dependencies` 打开时才被采用；关闭缓存依赖读取后这个缓存根没有用途，配置里写了也不会报错，只是不生效。`--cjpm-cache` 仍要求同一命令里打开缓存依赖，否则报 `--cjpm-cache requires --include-cached-dependencies`。
- `cache-dir` 不能落在输出目录内，否则冲突检查直接失败。

### `[semantic]`：语义模式

| 键 | 取值 | 默认 |
|---|---|---|
| `mode` | `source`、`chir` | `chir` |

```toml
[semantic]
mode = "source"
```

CLI 的 `--semantic` 默认就是 `chir`，与表中省略 `mode` 时一致；需要跳过 CHIR 编译时显式写 `--semantic source` 或设置本表。worker 路径只能通过 `--chir-worker` 给出，配置文件里没有对应键——项目配置不能指定要执行的外部程序。默认 worker 与 `cjdoc` 可执行文件同目录（`chir-worker-main`，Windows 为 `chir-worker-main.exe`）；缺失或不可执行时报 `CJDOC2101`，版本或协议不匹配时报 `CJDOC2104`，均保留源码声明并回退。

### 优先级与边界

- 优先级固定为：显式 CLI 值 → `cjdoc.toml` → 内置默认值。违反取值范围的配置即使被 CLI 覆盖也会报错，便于尽早发现拼写或取值错误。
- `[output]` 只决定产物，不影响诊断；`check` 的结果与是否配置 `[output]` 无关。
- `--force-owned`、`--stdout`、`--check-examples`、`--highlight-adapter`、`--highlight-node`、`--chir-worker` 只能出现在命令行：替换他人输出、一次性写 stdout、执行示例、运行外部程序都需要每次显式授权，配置文件不能预先授予。
- `--min-symbol-coverage`、`--min-parameter-coverage` 与 `[coverage]` 是两套独立门槛，同时检查，CLI 值不会覆盖配置值。
- 语言相关设置只在 `[i18n]`，本页三张表不重复定义；省略 `--locale` 时 generate/serve 使用 `[i18n].default-language`。
- `cjdoc serve` 每次重建都按原命令行重新读取配置，所以修改或删除本页的设置无需重启；输出目录、缓存目录和端口只在启动时确定，重建时若解析出不同位置会提示重启并保留旧站点。

## `[docs]`：项目首页与概念文档

出现 `[docs]`、`[[docs.pages]]` 或 `[docs.packages]` 任一项即启用概念文档：生成项目首页、每个已发现模块的模块页、每个已发现包的包页，以及配置的自定义页面。概念页与 API 文档一起输出并可被搜索。

| 键 | 类型 | 默认 | 约束与失败提示 |
|---|---|---|---|
| `index` | 字符串 | `docs/index.md` | 项目内安全相对 `.md` 路径；绝对路径、`\`、`..`、`:` 都报 `[docs] index must be a safe relative Markdown path` |
| `index-source` | 字符串 | 同 `index` | `index` 的别名；两者都出现时后读到的值生效 |

首页路由固定为 `concepts/index.html`。启用了概念文档但首页源文件不存在时生成默认项目页；模块页、包页的默认源文件是 `docs/modules/<slug>.md`、`docs/packages/<slug>.md`，缺失时生成中性默认正文。`slug` 把名称中 ASCII 字母、数字以外的字符折叠成连字符，全无安全字符时用 `page`。

### `[[docs.pages]]`：自定义指南或概念页

每条 `[[docs.pages]]` 声明一页。

| 键 | 类型 | 默认 | 约束与失败提示 |
|---|---|---|---|
| `source` | 字符串 | 无（必填） | 安全相对 `.md` 路径；文件必须存在，缺失报 `conceptual Markdown source does not exist: <路径>` |
| `path` | 字符串 | — | `source` 的同义键 |
| `route` | 字符串 | `concepts/guides/<源路径 slug>` | 必须在 `concepts/` 下；不能以 `/` 或 `\` 开头，不能含 `..`、`:`、`?`、`#` 或控制字符；未写 `.html` 自动补上。违规报 `[[docs.pages]] route must be a safe relative path` 或 `conceptual page route must stay under concepts/` |
| `title` | 字符串 | 源文件第一个非代码块、非缩进的 `# ` 标题，否则源路径 | 空值即采用默认 |
| `id` | 字符串 | `route` | 多语言配对用；带 `language` 却不写 `id` 报 `CJDOC3110 … requires an explicit id; page omitted` |
| `language` | `zh-CN` 或 `en` | 未指定时按配置的 `default-language` | 其他语言值报 `unsupported documentation language '<值>'` |
| `kind` | `guide`、`package`、`project`、`module` | `guide` | 其他值报 `invalid documentation page` |
| `package` | 字符串 | 无 | 关联包名；不替代页面绑定与包身份检查 |

单个源文件最多 256 KiB，概念页合计最多 128 页。同一语言内重复 `id` 于是报 `CJDOC3110` 并跳过重复页（首条保留）。同一语言内路由冲突保留可读前缀并加稳定后缀，报 `CJDOC4060` 并给出实际路由；实际路径以生成的导航索引为准。

### `[docs.pages.sections]`：多语言章节锚点

紧跟相应 `[[docs.pages]]`，把稳定章节 ID 映射到该页实际存在的 Markdown 标题锚点：

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

值是标题的锚点，不是标题原文：`Installation` 对应的值是 `installation`，`First example` 对应 `first-example`。空白转 `-`，ASCII 大写转小写，重复锚点追加 `-1`、`-2`。也接受页面里完整的 `standalone--doc-…` 标题 ID。锚点不存在、逻辑章节 ID 重复，或两条映射指向同一锚点时，该映射被忽略并报 `CJDOC3110` warning，页面其余内容照常生成。以生成页的实际链接为准，不要凭标题猜后缀。

### `[docs.packages]`：包概述源文件

两种写法都接受，值都是项目内相对 Markdown 路径：

```toml
[docs.packages]
pocketkit = "docs/pocketkit.md"

[docs.packages.pocketkit-core]
overview = "docs/pocketkit-core.md"
```

`[docs.packages]` 的键是包名、值是路径；`[docs.packages.<包名>]` 接受 `source`、`path`、`overview` 三个同义键。包名取 `docs.packages.` 之后的原样文本，带点的包名直接写在后面；包名不能是绝对路径或含 `\`、`..`、`:`，否则报 `[docs.packages] package name is unsafe`。没有对应已发现包的配置项不产生页面。

未配置源文件时读 `docs/packages/<slug>.md`；显式配置的文件缺失时也用默认包页，不报错——这一点与 `[[docs.pages]]` 缺文件不同。

## `[[source.repositories]]`：多仓源码来源登记

按源码根登记 GitHub 仓库，并用调用方独立 pin 的 receipt 校对本次读取的源码字节。文件最多 64 KiB，最多 4096 条登记。

```toml
[[source.repositories]]
root = "packages/core/src"
url = "https://github.com/example/core"
revision = "0123456789abcdef0123456789abcdef01234567"
repository-path = "src"
receipt = "evidence/core-source.json"
receipt-sha256 = "62d82220e8062eec9365e23130392a9fab35e38bff2e31ff6a1b058d380d68b6"
```

| 键 | 必需 | 规则 |
|---|---|---|
| `root` | 是 | 本地目录或单个源码文件，相对项目根或绝对路径；必须存在，不能是符号链接（报 `source repository root cannot be a symbolic link`） |
| `url` | 是 | `https://github.com/<owner>/<repo>` 形式的仓库根 |
| `revision` | 是 | 完整 40 位小写十六进制 commit SHA |
| `repository-path` | 否 | 仓库内的安全相对路径前缀，默认空；`root` 是单个文件时必须给出该文件的完整仓内路径（报 `file source roots require a complete repository path`） |
| `receipt` | 否 | `cjdoc.source-provenance/1` JSON 路径，相对项目根或绝对路径 |
| `receipt-sha256` | 否 | receipt 原始字节的 64 位小写 SHA-256；与 `receipt` 成对提供才可能得到 `verified` |

receipt 只能有 `schemaVersion`、`repository`、`files`：`schemaVersion` 为 `cjdoc.source-provenance/1`；`repository` 含 `url` 与 `revision`；每个 `files` 条目含唯一、安全的仓内 `path` 与原始字节 SHA-256。未知或重复键、额外字段、不安全路径都拒绝。`cjdoc schema source-provenance` 输出该协议。

pin 必须来自独立可信渠道并覆盖 receipt 的精确字节；只重排 JSON 或改换行就会改变 pin。只要配置了任一条登记，就进入严格登记模式：未匹配的文件不再回退到主仓或 `--repository-url`；重叠登记产生 `ambiguous`，不按前缀长度或顺序猜。receipt 缺失、未 pin、仓库不符或摘要不符时来源为 `unavailable`，报 `CJDOC1032` 并省略源码链接，API 内容仍保留。旧的单仓 `--repository-url` 映射标为 `declared`。

## `[metadata]`：分组与标签标题

元数据按发现的 module 读取：每个模块在自己的项目根读 `cjdoc.toml`；workspace 根配置不会自动传给成员项目或依赖。每个配置最多 64 KiB，group 和 tag 各最多 2048 条。

表头的路径分量支持单引号、双引号，以及点号两侧的空白。例如 `[["metadata"."groups"]]`、`[['metadata'.'groups']]` 与 `[[metadata . groups]]` 都表示同一种 group 表；tag 和 `titles` 子表也支持这些写法，记录作用域和重复定义规则不变。

```toml
[[metadata.groups]]
package = "pocketkit"
owner = "pocketkit.TextCatalog" # 或 owner-id，二者不可同时填写
id = "20-serialization"
title = "序列化"
order = 20

[metadata.groups.titles]
en = "Serialization"

[[metadata.tags]]
id = "streaming"
title = "流式"

[metadata.tags.titles]
en = "Streaming"
```

| 表 | 键 | 规则 |
|---|---|---|
| `[[metadata.groups]]` | `package`（必填） | 同一 module 内的包名 |
| | `id`（必填） | 1–64 个 ASCII 字母、数字、`-`、`_` |
| | `title`（必填） | 1–256 UTF-8 字节的单行纯文本，不得全空白或含 C0/DEL 控制字符 |
| | `owner` / `owner-id` | 二选一，同时写报 `owner and owner-id are mutually exclusive`；`owner` 是同包完整限定名，`owner-id` 是同 module/package 的完整 SymbolId；只接受 class、struct、interface、enum、extend |
| | `order` | `0..999999` 整数；越界报 `metadata 'order' must be in 0..999999` |
| `[[metadata.tags]]` | `id`、`title`（必填） | 规则同上；不接受 `package`、`owner`、`order` |
| `[metadata.groups.titles]`、`[metadata.tags.titles]` | `en`、`zh-CN` | 只允许这两种语言，其他键报 `metadata titles allow only 'en' and 'zh-CN'` |

`[metadata]` 本身可以出现但必须为空，写键报 `[metadata] does not allow keys`。除此之外只接受上面这些表；dotted key、inline table、未知表、重复键、类型错误都报 `CJDOC3133 at cjdoc.toml:<行>: <说明>`，退出码 `2`。

配置解析成功但绑定失败时，诊断保留、文档为 `partial`：`CJDOC3134` 指定的 package/owner 不存在，`CJDOC3135` owner 有歧义，`CJDOC3136` 同一 scope 内定义重复且竞争项都无效，`CJDOC3137` 无匹配定义的无标题 `@group` 简写。隐藏声明可以作为 owner 被绑定。

分组按显式 `order` 升序排在前，未指定顺序的组排在后面；标题只影响显示，不改变成员身份、SymbolId、API fingerprint 或翻译覆盖率。标签定义只提供显示标题，成员关系仍由每个声明显式写 `@tag <id>` 决定。语法细节见[文档注释参考](doc-comments.md#分组与标签)。

## `[comments]`：项目注释规范

`[comments]` 让项目沿用现有 `/** ... */` 注释，在所属模块的 `cjdoc.toml` 声明标签别名、正式字段、必填或条件必填规则。与 `[metadata]` 一样按发现的 module 读取：成员项目只读自己的配置，workspace 根配置不会传给成员，依赖也不会接收调用者的规则。只有工作区描述目录（自身不产生声明）的 `[comments]` 只做校验，不挂到任何成员。每个配置最多 64 KiB，别名、字段、规则各最多 2048 条。

```toml
[comments.aliases]
maintainer = "owner"   # 也可以指向内置标签，例如 rfc = "see"

[[comments.fields]]
id = "owner"           # [a-z][a-z0-9-]{0,63}
title = "负责人"
repeatable = false     # 默认 false；true 时同一字段可写多次

[comments.fields.titles]
en = "Owner"

[[comments.rules]]
require = "owner"
when-present = "deprecated"  # 省略表示所有可见声明都适用
severity = "warning"         # error（默认）或 warning
```

| 表 | 键 | 规则 |
|---|---|---|
| `[comments.aliases]` | `别名 = "目标"` | 别名与目标都符合 `[a-z][a-z0-9-]{0,63}`；目标只能是内置标签或本模块正式字段，不能指向另一个别名 |
| `[[comments.fields]]` | `id`、`title`（必填） | 字段名规则同别名；标题是 1–256 UTF-8 字节的单行纯文本 |
| | `repeatable` | `true` / `false`，默认 `false` |
| `[comments.fields.titles]` | `en`、`zh-CN` | 只允许这两种语言；页面按语言取标题，没有译名时用 `title` |
| `[[comments.rules]]` | `require`（必填） | 必填项，只接受正式名（内置标签或字段），不接受别名 |
| | `when-present` | 触发条件，只接受正式名；与 `require` 相同报配置错误 |
| | `severity` | `error`（默认）或 `warning`，不受 `[lint]` 控制 |

字段、别名都不能与内置标签（含 `note`、`warning`、`danger`）冲突。别名可以写在字段定义之前。未知表、未知键、类型错误、重复定义、孤立 `[comments.fields.titles]`、别名链或环、未知目标、规则引用别名，都报 `CJDOC3139 at cjdoc.toml:<行>: <说明>`，退出码 `2`；`--lint-profile off` 也照样报错。

注释里的写法与含义见[文档注释参考](doc-comments.md#项目注释字段)。

## `[limits]`：Doc IR JSON 大小

| 键 | 取值 | 默认 |
|---|---:|---:|
| `max-doc-ir-mib` | 整数 `1..64` | `64` |

```toml
[limits]
max-doc-ir-mib = 32
```

只能是单个 `[limits]` 表：顶层 `limits.max-doc-ir-mib` 报 `configure Doc IR limits with [limits]; dotted keys and inline tables are unsupported`，`[[limits]]`、子表、重复键、未知键、非整数都报错，即使同时给了 CLI 覆盖也一样。

`generate`、`check`、`serve` 的 `--max-doc-ir-mib` 覆盖配置值；`render` 不读配置，用默认值或自己的 CLI 值。输入文件按包含空白的原始字节计量；超过预算返回输入错误，生成阶段超限则保留有界回退并报 `CJDOC3027` warning。64 MiB 是硬上限，单字符串、产物数量与递归深度另有限制，见[状态与限制](states-and-limits.md#主要资源上限)。

## `[i18n]`：发布语言

| 键 | 取值 | 默认 | 规则 |
|---|---|---|---|
| `default-language` | `zh-CN`、`en` | 无 | 出现 `[i18n]` 时必填，缺失报 `CJDOC3105: [i18n] requires default-language` |
| `languages` | 字符串数组 | 只有 `default-language` | 只能列 `zh-CN`、`en`，最多两项，不可重复；空数组报 `[i18n].languages must not be empty`，多于两项报 `at most two publication languages are supported` |
| `missing-translation` | `warn`、`deny` | `warn` | 其他值报 `missing-translation must be warn or deny`；`deny` 把缺译诊断升级为 error |

```toml
[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"
```

未知键报 `unknown [i18n] setting '<键>'`，重复键报 `duplicate [i18n] key '<键>'`。语言不做 `zh-Hans`、`zh-TW`、`en-US` 之类的区域别名推断；`--all-languages` 要求本表显式列出语言，否则报 `--all-languages requires explicit [i18n] languages`。注释里的语言限定与译文回退见[文档注释参考](doc-comments.md#多语言注释)。

## `[lint]`：质量规则严重级别

| 键 | 取值 | 默认 |
|---|---|---|
| `severity` | `off`、`warning`、`error` | `warning` |
| 任一下列规则名 | `off`、`warning`、`error` | 跟随 `severity`，`example-not-compiling` 例外默认为 `error` |

未知键报 `unknown [lint] setting '<键>'`，非法严重级别报 `lint severity must be off, warning, or error`，同名规则重复报 `duplicate quality configuration setting 'lint:<键>'`。三条模板规则（`trivial-*`）与其它规则同源控制：`severity = "off"` 时一并关闭，也可按规则名单独设为 `off`、`warning` 或 `error`。

| 规则 | 检查内容 |
|---|---|
| `missing-summary` | 缺少摘要 |
| `missing-symbol-doc` | 可见符号完全没有注释 |
| `missing-param` | 参数缺少对应 `@param` |
| `missing-return` | 有非 `Unit` 返回值的声明缺 `@return` |
| `missing-throws` | `@throws` 没有说明 |
| `missing-example` | 符号缺少 `@example` |
| `empty-description` | 有摘要但没有详细说明 |
| `broken-link` | `@see` 引用目标不存在 |
| `ambiguous-link` | 引用目标无法唯一解析 |
| `unresolved-type-link` | 类型或语义引用无法解析 |
| `invalid-since-version` | `@since` 不是 2–4 段数字 |
| `deprecated-without-message` | `@deprecated` 缺弃用说明 |
| `duplicate-param` | 同一参数有多个 `@param` |
| `duplicate-return` | 有多个 `@return` |
| `duplicate-throws` | 同一异常有多个 `@throws` |
| `example-not-compiling` | 示例编译失败 |
| `trivial-summary` | 摘要整句只重复声明名（`CJDOC3047`） |
| `trivial-param-description` | `@param` 说明整句只重复参数名（`CJDOC3048`） |
| `trivial-return-description` | `@return` 说明整句只重复返回类型（`CJDOC3049`） |

```toml
[lint]
severity = "warning"
missing-example = "off"
broken-link = "error"
example-not-compiling = "error"
```

`--lint-profile off` 不运行质量规则，只做引用解析；`standard`（默认）运行其中一部分，不把「完全没有注释」升级为严格规则；`strict` 额外启用严格符号注释规则并检查缺失参数文档。`--deny-warnings` 让 warning 也导致失败。质量发现也写进 `coverage/quality.json`。

## `[coverage]`：覆盖率门槛

所有门槛是 `0..100` 整数，越界报 `coverage thresholds must be in 0..100`；非整数报 `[coverage].<键> must be an integer`。未设门槛的指标不检查。

| 键 | 分母与分子 |
|---|---|
| `symbols` | 可见声明数 / 其中有非空摘要的数量 |
| `parameters` | 可见参数（不含 `_` 开头）/ 其中有非空说明的数量 |
| `returns` | 有非 `Unit` 返回值的声明 / 其中有非空 `@return` 的数量 |
| `throws` | 实际记录的 `@throws` 条目 / 其中有非空说明的数量 |
| `examples` | 全部可见声明 / 其中有非空 `@example` 的数量；无注释声明也计入分母 |
| `deprecated` | 实际记录的 `@deprecated` 条目 / 其中有非空说明的数量 |
| `semantic-links` | 已记录语义链接 / 其中解析成功的数量 |

兼容的单数别名：`symbol`、`parameter`、`return`、`throws-docs`、`example`、`semantic-link`。标准键与别名重复出现仍是重复配置错误；未知键报 `unknown [coverage] setting '<键>'`。每个分母为 0 时按 100% 计。

### `[coverage.package.<包名>]` 与 `[coverage.translation]`

```toml
[coverage]
symbols = 90
parameters = 95

[coverage.package.basic]
symbols = 100

[coverage.translation]
en = 90
```

包级门槛接受与 `[coverage]` 相同的键，只覆盖该包显式设置的指标，其余继承全局值；包名必须是本次受众下的包，匹配不到时报 `package coverage override '<包名>' does not match any selected package` 并失败。包名不能为空或含空格、制表符（报 `coverage package override requires a safe package name`）。

`[coverage.translation]` 以语言名为键设 0–100 的最低翻译覆盖率，低于阈值报 `CJDOC3111`。非法语言报 `unsupported documentation language '<值>'`，重复语言报 `duplicate quality configuration setting 'coverage.translation:<语言>'`，越界报 `translation threshold must be in 0..100`。`check --require-language en` 等价于要求该语言达到 100%。

`generate` 与 `check` 都执行配置门槛；`--min-symbol-coverage`、`--min-parameter-coverage` 是另一套一次性门槛，同时检查而不覆盖配置。两套口径与报告指标的区别见[状态与限制](states-and-limits.md#覆盖率与质量统计)。

## `[highlight]`：代码高亮

| 键 | 取值 | 默认 | 规则 |
|---|---|---|---|
| `mode` | `static`、`off` | `static` | 其他值报 `[highlight].mode must be static or off`；`off` 时所有代码块按纯文本输出 |
| `languages` | 带引号的字符串数组 | `["cangjie"]` | 空数组报 `[highlight].languages must not be empty`；归一化后重复报 `[highlight].languages contains duplicate language '<值>'`；未列出的语言不高亮 |
| `on-error` | `warn`、`error` | `warn` | 其他值报 `[highlight].on-error must be warn or error` |

```toml
[highlight]
mode = "static"
languages = ["cangjie", "json"]
on-error = "warn"
```

未知键报 `unknown [highlight] setting '<键>'`，重复键报 `duplicate or empty [highlight] setting '<键>'`。`on-error = "warn"` 时高亮失败保留纯文本并报 `CJDOC3120` warning；`error` 时报 `CJDOC4027` error。

内置高亮只支持仓颉。`json`、`bash`、`python`、`toml`、`yaml` 需要外部适配器：把语言列进 `languages` 不会授权执行外部程序，还必须同时提供 `--highlight-adapter` 与 `--highlight-node`（都是绝对路径，仅 generate/check 可用）。未配置后端时这些语言保持纯文本并可能报 warning。准备步骤见[代码高亮](../how-to/highlighting.md)。

## `[external-docs.<名称>]`：旧式外部文档链接

兼容旧项目的表，只提供显式参考链接，不参与依赖自动匹配。新接入用文档 catalog 与库存 pin，见[链接外部文档](../how-to/link-documentation.md)。

| 键 | 含义 | 默认 |
|---|---|---|
| `index` | 外部文档索引文件路径，相对项目根或绝对 | 无 |
| `base-url` | `https://` 地址，或以 `./` 开头的相对文档根 | 无 |
| `version` | 展示用的文档版本文字 | 无 |

```toml
[external-docs.support]
index = "docs/support-index.json"
base-url = "https://docs.example.test/support"
version = "2.1"
```

`index` 或 `base-url` 缺失时该条来源状态为 `unavailable`；`base-url` 不安全时同样为 `unavailable`。这里声明的链接不是依赖匹配的证明，也不能凭配置声明 `verified`。

## 已移除的 `[doctest]`

出现 `[doctest]` 直接报配置错误 `[doctest] is no longer supported; use --check-examples and @example {run}`。示例执行改由注释里的 `@example` 指令加显式 `--check-examples` 启用，见[文档注释参考](doc-comments.md#示例)。

## 完整示例

下面这份 `cjdoc.toml` 与同名项目一起通过 `cjdoc check`（退出码 `0`，只剩该项目的文档内容警告）。它假设项目名 `pocketkit`，含 `src/api.cj`、`docs/index.md`、`docs/guides/start.md`、`docs/packages/pocketkit.md`，以及已用 `sha256sum` 取到摘要的 `evidence/source.json`。

```toml
[limits]
max-doc-ir-mib = 32

[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"

[lint]
severity = "warning"
missing-example = "off"
broken-link = "error"
example-not-compiling = "error"

[coverage]
symbols = 80
parameters = 90

[highlight]
mode = "static"
languages = ["cangjie"]
on-error = "warn"

[docs]
index = "docs/index.md"

[[docs.pages]]
source = "docs/guides/start.md"
route = "concepts/guides/start"
id = "start"
language = "zh-CN"
kind = "guide"

[docs.pages.sections]
install = "安装"

[docs.packages]
pocketkit = "docs/packages/pocketkit.md"

[[metadata.groups]]
package = "pocketkit"
id = "20-serialization"
title = "序列化"
order = 20

[metadata.groups.titles]
en = "Serialization"

[[metadata.tags]]
id = "streaming"
title = "流式"

[metadata.tags.titles]
en = "Streaming"

[[source.repositories]]
root = "src"
url = "https://github.com/example/pocketkit"
revision = "0123456789abcdef0123456789abcdef01234567"
repository-path = "src"
receipt = "evidence/source.json"
receipt-sha256 = "62d82220e8062eec9365e23130392a9fab35e38bff2e31ff6a1b058d380d68b6"
```

`receipt-sha256` 必须是该 receipt 文件的实际摘要；换掉仓库 URL、revision 或 receipt 内容都要同步更新，否则来源状态变成 `unavailable` 并报 `CJDOC1032`。
