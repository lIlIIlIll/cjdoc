# 配置参考

`cjdoc.toml` 放在项目根目录（即 `--project` 指向的目录），所有表都可省略。`generate`、`check`、`serve` 会读取这个文件；`render` 直接使用 `docs.json` 里已经保存的配置，不重新读取 `cjdoc.toml`。

配置写错（未知键、重复键、非法取值）时，命令会打印 `error:` 并以退出码 `2` 结束，不会生成文档。下面几节里，`[i18n]`、`[lint]`、`[coverage]` 及其子表、`[highlight]` 是严格解析的，出现不认识的键会报错；`[docs]`、`[[docs.pages]]`、`[docs.packages]` 只读取列出的键，键名写错会被静默忽略，改完配置后建议重新生成确认效果。

## [docs]：项目首页

| 键 | 含义 | 取值 | 默认值 | 约束 |
|---|---|---|---|---|
| `index` | 项目首页的 Markdown 源文件 | 项目内相对 `.md` 路径 | `docs/index.md` | 不能是绝对路径，不能含 `\`、`..`、`:` |
| `index-source` | 同上，别名 | 同上 | 同上 | 与 `index` 等价，后出现的为准 |

出现 `[docs]`、`[[docs.pages]]` 或 `[docs.packages]` 中任意一个，cjdoc 就会生成概念页：项目首页、模块页、包页，以及你配置的页面。首页路由固定为 `concepts/index.html`；首页文件不存在时会自动生成一份占位首页。写法和页面组织见 [概念页与指南](guides.md)。

```toml
[docs]
index = "README.md"
```

## [[docs.pages]]：自定义页面

每个 `[[docs.pages]]` 定义一个页面。页面源文件必须存在，否则命令报错。

| 键 | 含义 | 取值 | 默认值 | 约束 |
|---|---|---|---|---|
| `source` / `path` | Markdown 源文件 | 项目内相对 `.md` 路径 | 必填 | 不能是绝对路径，不能含 `\`、`..`、`:` |
| `route` | 页面在 HTML 站点中的路由 | 以 `concepts/` 开头的安全相对路径 | `concepts/guides/<源路径 slug>` | 不能含 `?`、`#`；没写 `.html` 时自动补上 |
| `title` | 页面标题 | 字符串 | 正文第一个 `# ` 标题 | 都没有时用源文件路径 |
| `id` | 逻辑页面 ID | 字符串 | 同 `route` | 多语言配对用；写了 `language` 时必须显式提供 |
| `language` | 页面正文语言 | `zh-CN` 或 `en` | `[i18n].default-language`（源文件存在时） | 未启用 `[i18n]` 时通常省略 |
| `kind` | 页面类别标签 | 字符串 | `guide` | 写入 `html/navigation-index.json`；`package` 表示正式包概述、`project` 表示项目首页、`concept` 会列入 `html/llms.txt` |
| `package` | 关联的包名 | 包名 | 无 | 把页面作为该包的概述候选，见下一节 |

```toml
[[docs.pages]]
source = "docs/getting-started.md"
route = "concepts/guides/getting-started"
title = "快速开始"
id = "getting-started"
kind = "guide"
```

同一个 `id` 搭配不同 `language` 表示同一逻辑页的不同语言版本；同一个 `id` 在一种语言内重复会报错（`CJDOC3110`）并跳过页面。

### [docs.pages.sections]：章节映射

`[docs.pages.sections]` 跟在某个 `[[docs.pages]]` 后面（或写在它的键后面），把逻辑章节 ID 映射到该页里真实的 Markdown 标题文本：

```toml
[[docs.pages]]
source = "docs/getting-started.md"
route = "concepts/guides/getting-started"
id = "getting-started"

[docs.pages.sections]
install = "安装"
first-example = "第一个示例"
```

| 键 | 含义 | 取值 | 默认值 | 约束 |
|---|---|---|---|---|
| `<章节 ID>` | 逻辑章节标识 | 字符串 | 无 | 同一页面内不能重复 |
| 值 | 该章节在 Markdown 里的标题文本 | 字符串 | 无 | 必须能在页面中唯一匹配到一个标题，否则映射被忽略并输出 warning（`CJDOC3110`） |

章节映射主要给多语言页面使用：同一逻辑页的不同语言版本用相同的章节 ID 指向各自语言的标题，切换语言时能跳到等价章节。不需要多语言时可以省略。

## [docs.packages]：包概述

有两种等价写法。包名用生成文档里显示的包名（例如 `pocketkit` 或 `basic`）。

| 写法 | 键 | 作用 |
|---|---|---|
| `[docs.packages]` | `<包名> = "<路径>.md"` | 一个包一行；包名直接写在等号左边，不要加引号 |
| `[docs.packages.<包名>]` | `source` / `path` / `overview` | 子表写法，三种键等价；带点的包名（如 `std.collection`）或不希望写扁平表时用这种写法 |

```toml
[docs.packages]
pocketkit = "docs/pocketkit.md"

[docs.packages.pocketkit-core]
overview = "docs/pocketkit-core.md"
```

| 项 | 取值 | 默认值 | 约束 |
|---|---|---|---|
| 包名 | 生成文档中的包名 | 无 | 不能含 `\`、`..`、`:`，不能是绝对路径；写一个不存在的包不会报错，也不会生成页面 |
| 路径 | 项目内相对 `.md` 路径 | 自动路径 `docs/packages/<slug>.md` | 文件不存在时使用自动占位页，不报错 |

包概述页的第一段（最多 240 个字符）会显示在 HTML 包页上，并链接到完整的概念页。要让概述出现在包页上，页面需要有正文，且页面里的 `cjdoc-bind` 必须全部能解析；同一个 Markdown 文件只保留一个入口。`kind = "package"` 的页面优先作为正式概述，普通指南页作为候选。

`slug` 是包名去掉 ASCII 字母和数字之外的字符后折叠成的短名，例如 `pocketkit-core`；自动包页路由为 `concepts/packages/<slug>.html`。

## [i18n]：多语言

| 键 | 含义 | 取值 | 默认值 | 约束 |
|---|---|---|---|---|
| `default-language` | 默认语言 | `zh-CN` 或 `en` | 无（出现 `[i18n]` 时必填） | 缺失时报错（`CJDOC3105`） |
| `languages` | 要发布的语言列表 | 带引号的字符串数组，最多 2 项 | `["<default-language>"]` | 只能包含 `zh-CN`、`en`，不能重复，空数组报错 |
| `missing-translation` | 缺译时的处理 | `warn` 或 `deny` | `warn` | `deny` 时缺译按 error 报告（`CJDOC3108`） |

```toml
[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"
```

出现 `[i18n]` 表即启用多语言。注释里的语言标记、页面配对和翻译覆盖率规则见 [多语言文档](i18n.md)。

## [lint]：质量规则

| 键 | 含义 | 取值 | 默认值 |
|---|---|---|---|
| `severity` | 未单独配置的规则的默认级别 | `off`、`warning` 或 `error` | `warning` |
| 规则名（见下表） | 覆盖单条规则的级别 | `off`、`warning` 或 `error` | 跟随 `severity` |

| 规则名 | 检查内容 |
|---|---|
| `missing-summary` | 符号缺少摘要 |
| `missing-symbol-doc` | 可见符号完全没有文档注释 |
| `missing-param` | 参数没有对应的 `@param` 说明 |
| `missing-return` | 有返回值的声明缺少 `@return` |
| `missing-throws` | `@throws` 没有写说明 |
| `missing-example` | 符号缺少 `@example` |
| `empty-description` | 有摘要但没有描述正文 |
| `broken-link` | `@see` 等引用指向不存在的目标 |
| `ambiguous-link` | `@see` 等引用无法唯一确定目标 |
| `unresolved-type-link` | 类型或语义引用无法解析 |
| `invalid-since-version` | `@since` 不是 2 到 4 段数字 |
| `deprecated-without-message` | `@deprecated` 没有写弃用说明 |
| `duplicate-param` | 同一参数写了多个 `@param` |
| `duplicate-return` | 写了多个 `@return` |
| `duplicate-throws` | 同一异常写了多个 `@throws` |
| `example-not-compiling` | 示例自身编译失败（`CJDOC3030`） |

```toml
[lint]
severity = "warning"
missing-example = "off"
broken-link = "error"
```

`--lint-profile off` 时不执行这些规则；`standard` 和 `strict` 下按上面的级别报告。命中结果会写入终端诊断；生成 `coverage` 格式时还会出现在 `coverage/quality.json`。加 `--deny-warnings` 可以让 warning 也导致失败。规则的具体含义和改进方法见 [文档质量检查](documentation-quality.md)。

## [coverage]：覆盖率门槛

| 键 | 指标 | 取值 | 默认值 |
|---|---|---|---|
| `symbols` | 有摘要的可见符号占比 | 0 到 100 的整数 | 不设门槛 |
| `parameters` | 有 `@param` 说明的参数占比 | 0 到 100 的整数 | 不设门槛 |
| `returns` | 有 `@return` 说明的返回值占比 | 0 到 100 的整数 | 不设门槛 |
| `throws` | `@throws` 带说明的占比 | 0 到 100 的整数 | 不设门槛 |
| `examples` | 带 `@example` 的符号占比 | 0 到 100 的整数 | 不设门槛 |
| `deprecated` | `@deprecated` 带说明的占比 | 0 到 100 的整数 | 不设门槛 |
| `semantic-links` | 语义引用能解析的占比 | 0 到 100 的整数 | 不设门槛 |

百分数按可见声明计算。除上表外也接受单数别名：`symbol`、`parameter`、`return`、`throws-docs`、`example`、`semantic-link`。

`generate` 和 `check` 都会执行配置里的门槛（`render` 不执行），低于门槛时报 error 并以退出码 `1` 结束。`check` 还可以用 `--min-symbol-coverage` 和 `--min-parameter-coverage` 临时追加一次性门槛，配置和命令行会同时检查。

### [coverage.package.<包名>]

按包覆盖同一个指标集合，没写的指标继承 `[coverage]`：

```toml
[coverage]
symbols = 90
parameters = 95

[coverage.package.basic]
symbols = 100
```

| 项 | 取值 | 约束 |
|---|---|---|
| 包名 | 生成文档中的包名 | 必须能匹配到本次生成的包，匹配不到时报错；指标取值范围与 `[coverage]` 相同 |

### [coverage.translation]

为每种语言设置最低翻译覆盖率：

```toml
[coverage.translation]
en = 90
```

| 键 | 含义 | 取值 | 约束 |
|---|---|---|---|
| `<语言>` | 该语言的翻译覆盖率下限 | 0 到 100 的整数 | 语言只支持 `zh-CN`、`en`，同一语言不能重复 |

低于阈值时输出 error（`CJDOC3111`）并使构建失败。`--require-language <语言>` 等价于把该语言的阈值设为 100。缺译策略和覆盖率算法见 [多语言文档](i18n.md)。

## [highlight]：代码高亮

| 键 | 含义 | 取值 | 默认值 | 约束 |
|---|---|---|---|---|
| `mode` | 高亮模式 | `static` 或 `off` | `static` | `off` 时所有代码块输出纯文本 |
| `languages` | 要应用高亮的代码语言 | 带引号的字符串数组 | `["cangjie"]` | 不能为空、不能重复，元素不能是空串或纯文本 |
| `on-error` | 高亮后端失败时的处理 | `warn` 或 `error` | `warn` | `warn` 保留纯文本并输出 warning（`CJDOC3120`）；`error` 报 error（`CJDOC4027`）并使构建失败 |

```toml
[highlight]
mode = "static"
languages = ["cangjie"]
on-error = "warn"
```

只有 `languages` 里列出的语言会被高亮，其他语言的代码块保持纯文本。内置高亮只覆盖仓颉；`json`、`bash`、`python`、`toml`、`yaml` 可以交给外部高亮后端（`--highlight-adapter` 和 `--highlight-node` 必须成对使用，用法见 [高级用法](advanced-usage.md)）；其他语言即使列出来也只显示纯文本。没有配置外部后端时，可外部高亮的语言会保留纯文本并输出 warning（`CJDOC3120`）。

## [external-docs.<名称>]：旧项目兼容的显式外部文档

这是旧版的配置方式，仅为兼容旧项目保留：手工声明外部文档索引和地址，只作为显式参考链接，不参与自动依赖匹配。新项目建议用 `--doc-source` 接入本地文档目录。

| 键 | 含义 | 取值 | 默认值 |
|---|---|---|---|
| `index` | 外部文档索引文件 | 项目内相对路径或绝对路径 | 无 |
| `base-url` | 外部文档根地址 | `https://` 地址或以 `./` 开头的相对路径 | 无 |
| `version` | 展示的文档版本 | 字符串 | 无 |

`--doc-source` 的用法见 [高级用法](advanced-usage.md)，两种方式的完整规则见 [跨文档链接维护](maintainer/document-links.md)。

```toml
[external-docs.support]
index = "docs/support-index.json"
base-url = "https://docs.example.test/support"
version = "2.1"
```

## [doctest] 已移除

旧版的 `[doctest]` 表已经移除，写进 `cjdoc.toml` 会直接报错并以退出码 `2` 结束。示例检查改用注释里的 `@example` 指令和 `--check-examples`，写法见 [使用手册](usage.md)。

## 完整示例

下面把主要配置放在一起，实际项目按需删减：

```toml
[docs]
index = "docs/index.md"

[[docs.pages]]
source = "docs/getting-started.md"
route = "concepts/guides/getting-started"
title = "快速开始"
id = "getting-started"
kind = "guide"

[docs.pages.sections]
install = "安装"
first-example = "第一个示例"

[[docs.pages]]
source = "docs/en/getting-started.md"
route = "concepts/guides/getting-started"
title = "Getting started"
id = "getting-started"
language = "en"

[docs.pages.sections]
install = "Installation"
first-example = "First example"

[docs.packages]
pocketkit = "docs/pocketkit.md"

[docs.packages.pocketkit-core]
overview = "docs/pocketkit-core.md"

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
```
