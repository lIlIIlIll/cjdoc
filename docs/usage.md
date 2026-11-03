# 使用手册

本文面向第一次使用 cjdoc 的仓颉库作者，说明从写注释到生成、检查、预览文档的日常操作。示例使用 cjdoc 0.7.6，命令在项目根目录执行。

开始前确认：

- 已安装仓颉 SDK，并按 SDK 自带的环境脚本配置好环境（`cjc -v`、`cjpm -v` 可用）；cjdoc 发布包不包含 SDK。
- 已按 [README](../README.md) 安装 cjdoc，`cjdoc --version` 输出 `cjdoc 0.7.6`。
- 命令在包含 `cjpm.toml` 的项目根目录运行；换目录时用 `--project <项目根>` 指定。

cjdoc 只有顶层 `cjdoc --help` / `cjdoc -h`；子命令没有单独的帮助。参数写错时，错误信息会附上用法并以退出码 `2` 结束。

## 确认安装

```bash
cjdoc --version
cjdoc --help
cjc -v
cjpm -v
```

`cjdoc --version` 应输出：

```text
cjdoc 0.7.6
```

`cjdoc --help` 会列出所有命令和主要选项。如果没有安装仓颉 SDK 或 SDK 环境没有生效，cjdoc 可能启动失败或报告缺少运行库；`--check-examples` 另外要求 `cjc` 在 `PATH` 中。

## 准备项目

在项目根目录准备 `cjpm.toml` 和 `src/`：

```text
my-project/
├── cjpm.toml
├── cjdoc.toml          # 可选：质量规则、覆盖率阈值等配置
└── src/
    └── api.cj
```

- `--project` 指向包含 `cjpm.toml` 的目录，默认是当前目录 `.`。
- 默认输出目录是项目下的 `target/doc`，不需要预先创建。
- 可选的项目根目录配置 `cjdoc.toml` 用于 lint、覆盖率阈值、代码高亮、多语言和概念页，完整配置键见 [配置参考](configuration.md)。

## 写文档注释

### 基本规则

- 只有 `/** ... */` 注释会生成文档；普通的 `//` 和 `/* ... */` 注释不绑定到声明。
- 注释紧贴在要文档化的声明前面。
- 正文第一段是摘要（summary），后面的段落是描述（description）。
- 正文支持 Markdown：段落、列表、行内代码和代码块都会保留。
- 默认只展示 `public` 和 `protected` 声明，`internal`、`private` 声明需要用 `--audience` 显式包含（见下文）。

### 宏声明与宏包裹的源码

`public macro` 使用与函数相同的注释标签。cjdoc 收集宏的源码签名、参数和返回类型，
并在 HTML 的“宏”分组中展示。`@param` 和 `@return` 参与文档质量与覆盖率检查。

对于 `@Derive[Equatable]` 等包裹声明的宏调用，cjdoc 收集输入中的源码声明和成员。
声明前的注释绑定到整个宏包裹的声明，成员保留各自的源码位置。嵌套宏同样适用。

cjdoc 不执行宏。宏调用保留在 `macroInvocations` 中，并通过 `CJDOC1009` 说明生成成员未知，
文档状态保持 `partial`。无法恢复为源码声明的输入还会进入 `unsupportedDeclarations`。
宏生成的方法、接口实现和其他成员不进入 API 清单；源码中已有的声明仍可搜索、链接和离线查询。

### 支持的标签

常用标签：

| 标签 | 用途 |
|---|---|
| `@param` | 参数说明，格式为 `@param 参数名 说明`。 |
| `@return` | 返回值说明。 |
| `@throws` | 可能抛出的异常，格式为 `@throws 异常类型 说明`。 |
| `@see` | 相关 API 引用，会被解析和检查。 |
| `@since` | 引入版本，写成 2 到 4 段数字，例如 `0.1.0`。 |
| `@deprecated` | 标记不再建议使用，建议同时写弃用原因。 |
| `@author` | 作者，可重复写多行。 |
| `@version` | 版本标记。 |
| `@example` | 示例代码块，详见下一节。 |
| `@group` | 源码声明分组，格式为 `@group 稳定标识 纯文本标题`。 |
| `@tag` | 声明级分类标签，格式为 `@tag 稳定标识`，每个声明可重复多个。 |
| `@note`、`@warning`、`@danger` | 作者明确标注的注意、警告或危险提示；完整语法见下文。 |

### 写提示

提示标签只识别小写 `@note`、`@warning` 和 `@danger`，且必须写在注释的顶层。标签后的连续非空顶层普通文本行属于提示正文；空行、下一条顶层 `@...` 行（即使它不是已知标签）、离开顶层普通文本结构或注释结束都会终止正文。未知顶层标签仍作为普通正文保留。若后面还有普通描述段落，用空行与提示分开。复杂的列表、表格、代码块等内容用 Markdown 提示块，见[概念页与指南](guides.md#markdown-提示块)。

可选属性只接受以下顺序，不加空格或引号：

```text
@warning
@warning[id=stale-cache]
@warning[lang=en]
@warning[lang=en,id=stale-cache]
```

例如：

~~~cangjie
/**
 * Loads the cached response.
 *
 * @warning[id=stale-cache] The cache may contain data from before the latest update.
 * Check its timestamp before using it.
 *
 * This ordinary paragraph is not part of the warning.
 */
public func loadResponse(): Response { ... }
~~~

`id` 是 1–64 个 ASCII 字节，必须以小写 `a-z` 开头，其余只能是小写字母、数字、`_` 或 `-`。例如 `id=stale-cache` 合法，`id=Stale-cache`、`id=1st-cache` 和 `id=` 非法。属性顺序反过来（`[id=stale-cache,lang=en]`）、未知/重复属性、带引号或带空格的属性也非法。`@Warning`、`@noteish`、代码、引用和列表中的相似文字保留为普通正文；无效提示头及其文字也会保留为正文并给出诊断。提示正文为空会报 `CJDOC3117`。

仅含 Markdown 引用定义（如 `[ref]: https://example.test/reference`）、解析后没有正文节点的提示也视为空提示：报告 `CJDOC3117`，保留作者原文，但不输出空提示框。请在引用定义之外补充可见正文。

这些级别由作者明确选择，cjdoc 不根据文字推断风险。HTML 使用静态、带可见本地化等级标题的提示块；正文继续走安全 Markdown renderer，不把作者内容作为 HTML 插入，也不创建弹窗、`role="alert"` 或 live region。折叠成员的 warning/danger 会显示紧凑等级徽标，note 不加风险徽标。多语言 ID 配对与仅提示本地化见[多语言文档](i18n.md#为提示正文配对语言)。

诊断码：`CJDOC3115` 表示提示属性结构或语法错误（语言值格式/支持性错误使用 `CJDOC3102`/`CJDOC3103`），`CJDOC3116` 表示 ID 错误，`CJDOC3117` 表示空提示；相同 ID 在同一语言重复，或跨提示等级复用，会报 `CJDOC3118`。

行为契约标签用于描述调用约定，会在页面的“行为契约”区域分组显示：

| 标签 | 用途 |
|---|---|
| `@precondition` | 调用前必须成立的条件（前置条件）。 |
| `@postcondition` | 调用后保证成立的结果（后置条件）。 |
| `@invariant` | 始终成立的不变量。 |
| `@performance` | 性能特征或复杂度说明。 |
| `@state` | 对状态的读取或影响说明。 |
| `@concurrency` | 并发安全与同步要求。 |
| `@platform` | 平台或运行环境限制。 |
| `@compatibility` | 版本或接口兼容性说明。 |
| `@error` | 错误处理与失败行为。 |

除单行元数据 `@group` 和 `@tag` 外，标签后面的说明可以换行续写。无法识别的 `@xxx` 会按普通正文处理。代码块里的 `@param` 等文字不会当成标签解析。

### 按使用对象分组

在声明的注释中写 `@group <id> <标题>`，把同一包或声明容器里的声明按职责组织。标题可留空，改用当前 module 的 `cjdoc.toml` 集中定义。

```cangjie
/**
 * 将一个值写为 JSON 文本。
 * @group 10-application 应用 API
 */
public func write(): Unit {}
```

组 ID 为 1 到 64 个 ASCII 字母、数字、连字符或下划线；内联标题为 1 到 256 个 UTF-8 字节的单行纯文本。每个声明最多指定一个组。`@group <id>` 的无标题简写只有在相同 module、package 和 owner scope 中存在有效集中定义时才生效。

分组顺序先按显式 `order`，再按组 ID；没有显式 order 的组排在有 order 的组之后，未分组声明最后。分组 scope 是 module、package 和声明的原始 owner：同一组 ID 若在不同包或不同 owner 中使用，会作为不同组呈现。分组仅影响展示，不改变 API 标识或可见性。

标题显示时优先使用当前界面语言的译名，再使用基础标题、合法内联标题，最后回退到组 ID。包页和类型页按发布投影后的可见种类数决定标题层级：单一种类时不重复输出种类标题，多个种类时才在组标题下分种类显示；Markdown 与 HTML 使用相同分区。重载和成员详情在真实父标题下继续嵌套。

分组保留历史深链：包页 `declarations`、组锚点 `api-group-<id>`、未分组锚点 `api-ungrouped`、种类锚点 `api-kind-<id长度>-<id>-<kindId>`、旧裸 kind ID 别名、symbol 锚点和详情锚点均保持可达。被省略的单一种类标题仍保留零高度别名锚点。
同一页面中同一 group ID 若落在多个 module/package/原始 owner scope，旧 `api-group-<id>` 与旧裸 kind 锚点只保留给一个确定的 primary scope：页面自身容器优先，否则按 scopeKey 的 UTF-8 字节序选择。其他 scope 有独立的 group/kind 锚点；primary 选择和锚点身份不受显示标题或排序 order 影响。

`@group[lang=...]` 会报 `CJDOC3112`，非法或重复内联组会报 `CJDOC3130`，同一 scope 的内联标题冲突会报 `CJDOC3131`。集中定义的配置语法和绑定诊断见[配置参考](configuration.md)的 metadata 一节。

分组不改变仓颉 API 契约，也不构成接口兼容性承诺。

### 声明标签

`@tag` 给声明附加可重复的分类标签，与 `@group` 的页面组织互不替代：

```cangjie
/**
 * 以流式方式写出 JSON 数据。
 * @group 20-serialization 序列化
 * @tag streaming
 * @tag extension-point
 */
public func writeJson(): Unit {}
```

标签 ID 为 1 到 64 个 ASCII 字母、数字、连字符或下划线，大小写敏感并按完整 ID 精确匹配，因此 `stream` 和 `Stream` 是不同标签。同一声明重复写相同 ID 时按集合去重，输出顺序按 ID 的 UTF-8 字节序排列。
标签必须单独占一行，不接续正文；多余参数、空 ID、非法字符或超长 ID 会报告 `CJDOC3132`。非法项不进入有效标签集合，但不会删除声明。`@tag[lang=...]` 会报 `CJDOC3112`，因为标签成员关系跨语言共享。

标签只属于写有该注释的声明：类型、包、基类和扩展不会把标签传给成员，各重载分别保留自己的标签。标签不是行为契约，不进入“行为契约”区域、契约质量分或翻译覆盖率分母；改标签只改变文档元数据，不改变 `SymbolId`、源码签名、可见性或重载族。

标签标题可以在[模块级元数据配置](configuration.md)中定义；没有集中标题时显示 ID。HTML 的 `tag:<id>` 输入和固定查询的 `tags` 字段都按 ID 精确匹配，不按标题或正文匹配；多个标签使用 AND 交集。包页和类型成员页中的标签链接会把当前 locale、snapshot 与 module 带到搜索页。

### 一个完整的例子

```cangjie
/**
 * 从文本中读取一个整数。
 *
 * 这是补充说明，会显示在摘要之后，支持 Markdown。
 *
 * @param text 要读取的文本。
 * @return 读取到的整数。
 * @throws IllegalArgumentException 文本不是合法整数时抛出。
 * @see parseOrNull
 * @since 0.1.0
 * @author your-name
 * @version 1
 */
public func parse(text: String): Int64 {
    return 42
}
```

检查注释质量时，`check` 会报告缺少摘要、参数名写错、`@see` 引用无法解析、`@since` 版本格式不合法等问题。规则和配置方式见 [文档质量检查](documentation-quality.md)。

## 用 `@example` 写示例

### 示例写法

在注释里用 `@example` 开一个示例，示例正文中放语言标记为 `cangjie` 的代码块：

~~~cangjie
/**
 * 计算两个整数的和。
 *
 * @example 基本用法
 * ```cangjie
 * let sum = add(1, 2)
 * println(sum)
 * ```
 *
 * @param left 左侧数值。
 * @param right 右侧数值。
 * @return 两数之和。
 */
public func add(left: Int64, right: Int64): Int64 {
    return left + right
}
~~~

- `@example` 后面可以直接写标题，标题可省略。
- 一个 `@example` 里可以有多个 `cangjie` 代码块，会按顺序拼成一段代码。
- 示例内容持续到下一个受支持的顶层标签；`@param`、`@return`、`@deprecated`、`@author 名称` 和 `@version 版本` 等标签会结束上一个示例。代码围栏中的相同文字仍属于示例内容。
- HTML 和 Markdown 输出都会渲染示例；默认**不编译、不运行**示例。

### 示例指令

需要校验示例时，在 `@example` 标题后加一对花括号写指令，指令之间用空格分隔，带值的指令写成 `name="value"`：

| 指令 | 含义 |
|---|---|
| `must-pass` | 该示例必须编译通过，并且检查必须真的发生。 |
| `must-fail` | 该示例必须编译失败，并且失败必须发生在示例代码里。 |
| `error="…"` | 与 `must-fail` 搭配，要求编译器输出包含这段文字。 |
| `run` | 编译通过后把示例作为程序运行，要求退出码为 0。 |
| `flags="…"` | 给该示例的 `cjc` 调用追加编译选项，只接受下面的白名单。 |

指令名区分大小写，不能重复。`must-pass` 与 `must-fail` 互斥，`run` 不能和 `must-fail` 一起用，`error=` 必须搭配 `must-fail`。语法错误、冲突、未知指令以及白名单之外的编译选项都会报告 `CJDOC3033`，这个示例不会被编译。

综合示例：

~~~cangjie
/**
 * @example 故意失败的调用 {must-fail error="undeclared identifier"}
 * ```cangjie
 * let missing = missingApi(1, 2)
 * ```
 *
 * @example 运行并固定输出 {run flags="--int-overflow wrapping"}
 * ```cangjie
 * println(add(1, 2))
 * ```
 * ```output
 * 3
 * ```
 */
~~~

`flags="…"` 接受的编译选项：

- `--cfg NAME=VALUE`：只接受用户自定义的配置键；`os`、`arch` 等内建键由 `cjc` 拒绝。
- `-Woff GROUP` / `-Won GROUP`：`all`、`unused`、`unused-main`、`deprecated`、`unsupport-compile-source`、`package-import`、`parser`、`semantics`、`interpreter`、`apilevel-check`。
- `--int-overflow throwing|wrapping|saturating`。
- 单独出现的 `--experimental`、`-O0`、`-O1`、`-O2`、`-Os`、`-Oz`。

输出路径、链接、包和 import 相关的选项由 cjdoc 自己掌握，写在 `flags` 里会失败。

### 固定标准输出

- 用语言标记为 `output` 的代码块固定标准输出，每个 `@example` 最多一个，并且必须和 `run` 一起用。
- 比较前会统一换行符并去掉首尾空行，所以 `println` 结尾的那个换行不需要写出来。

### 运行示例

- 示例会被包装成一个无参数的 `main` 运行，因此示例里不能使用 `args`。
- 需要 `import` 时，写在示例所属的源码文件里；示例只写可以放进函数体的代码片段。
- 运行可执行文件用静态链接构建；静态链接不可用的环境会报告 `CJDOC3074`。

单次检查的限制是固定的：

| 限制 | 值 |
|---|---|
| 单次运行时间 | 10 秒，超时报告 `CJDOC3073` |
| stdout 上限 | 64 KiB，超限报告 `CJDOC3075` |
| stderr 上限 | 64 KiB，超限报告 `CJDOC3075` |
| 内存上限 | 2048 MiB；无法建立地址空间限制时拒绝运行并报告 `CJDOC3074`，例如没有可用 `prlimit` 的 macOS 环境 |
| 一次检查的示例总数 | 最多 256 个 |

示例检查的其他结果：

- 编译器将错误归因到生成的示例文件：`CJDOC3030`。
- 未归因到该文件的编译失败（例如源码包上下文无法编译）：`CJDOC3031`。
- 固定了结果但没有真正检查（例如因数量限制被跳过）：`CJDOC3070`。
- 运行退出码不是 0：`CJDOC3071`。
- 标准输出和 `output` 块不一致：`CJDOC3072`。

结果通过诊断和退出码呈现，不生成逐例结果文件或页面执行徽标。

### 检查示例

示例检查是显式开关，默认不生效：

```bash
cjdoc check --project . --check-examples
```

`generate` 也接受 `--check-examples`，在生成文档的同时检查示例：

```bash
cjdoc generate --project . --format html --check-examples
```

旧配置里的 `[doctest]` 表已经移除，出现时会直接报错。请删除该表，改用 `--check-examples` 和 `@example` 指令。

## 生成 HTML

```bash
cjdoc generate --project . --format html
```

默认输出到 `target/doc`，入口是：

```text
target/doc/html/index.html
```

`html/` 目录里还有包页、声明页、搜索索引、`llms.txt`、样式和脚本等静态资源。HTML 内置搜索、主题切换和移动端导航，直接用浏览器打开即可，不需要服务器。

### 在静态页面中查找 API

- 浏览器搜索使用 discovery 排名和 bounded-static 投影。名称、参数等结构化字段不截断；每项正文最多索引 2,000 个 Unicode 码点，`coverage` 字段标明正文索引是否完整。没有正文命中不证明超出静态索引范围的内容不存在。
- 可用 `name:`、`owner:`、`param:`、`return:`、`package:`、`kind:` 过滤，例如 `owner:TextCatalog param:String`。这些文本字段按包含关系匹配；页面上的 package/kind 下拉项使用精确匹配。
- 重复写 `tag:<id>` 可交集筛选多个分类。ID 区分大小写，显示标题不作为查询 ID；标签项保留 module 和 snapshot 身份，facet 计数按当前全部条件筛选后的可见声明计算。
- 搜索输入和过滤条件改变时回到第一页；全站结果使用稳定的相关度、snapshot ID 和声明 ID 顺序，完整结果总数不只计算当前页。搜索语义、原生请求及游标边界见[机器读取手册](agent-reading.md#search-与固定查询)。
- 类型页的正文成员筛选覆盖全部可见成员，独立于侧栏最多 256 项的上下文列表。标签筛选按每条可见签名的精确身份读取分类，不从展示文字推断，也不把同一重载族的标签取并集；匹配数是命中的签名数/原总数。零匹配的种类、重载标题、外层组及相应 TOC 项会隐藏，匹配数随之更新但不重编号锚点；运行时筛选不改变标题层级。精确成员链接会揭示被筛选隐藏的目标；返回历史仍保留筛选、展开状态及阅读位置。
- 搜索支持键盘方向键、Enter、Escape 和 Ctrl/Cmd+K；中文等 IME 组合期间不会激活中间结果。也可用键盘焦点或触屏操作翻页按钮，真实 `file://` 不需要网络服务。


### 输出选项

常用做法：

- 换输出目录：`cjdoc generate --project . --format html --output target/doc-custom`。
- 一次生成多种格式：重复写 `--format`；JSON 产物是输出目录根下的 `docs.json`，其余格式各有子目录。
- 修改注释后重新运行同一条命令，刷新页面即可。
- 在页面上显示文档版本：加上 `--doc-version 1.0.0`（要求同时生成 `--format html`），页面会显示版本标签并输出 `html/version.json`。
- 给脚本或 AI 代理独立读取声明：普通 HTML 已发布 `agent/manifest.json`、逐声明 Markdown/JSON、`llms.txt` 和可续取导航；`--agent-full` 另加聚合全文/分片索引。固定文档查询与本地 MCP 见[机器读取手册](agent-reading.md)。
- 标准库链接：文档里引用标准库类型时，cjdoc 会链接到对应版本的官方标准库文档；默认使用能观察到的标准库版本，取不到时用 1.2.0。要指定版本用 `--stdlib-doc-version`，内置版本有 `1.0.5`、`1.1.0`、`1.1.0-beta.25`、`1.1.3`、`1.2.0`；自定义地址用 `--stdlib-doc-base-url`，必须是 HTTPS 且以 `/libs/std` 结尾。

代码高亮默认开启，可以在 `cjdoc.toml` 的 `[highlight]` 中关闭或调整。相关配置见 [配置参考](configuration.md)。

## 生成 Markdown

```bash
cjdoc generate --project . --format markdown
```

入口是 `target/doc/markdown/index.md`，同目录下还有按包和声明拆分的页面。Markdown 适合提交到仓库，或接入已有的文档站点。

`--locale zh-CN`（默认）或 `--locale en` 控制页面里的标签语言；作者正文的语言由 `[i18n]` 配置和注释里的语言标记决定，见 [多语言文档](i18n.md)。

## 生成 JSON

```bash
cjdoc generate --project . --format json
```

产物是 `target/doc/docs.json`。不写 `--format` 时，cjdoc 默认只生成这个文件。JSON 适合交给其他工具做二次处理。

把 JSON 写到标准输出：

```bash
cjdoc generate --project . --format json --stdout > docs.json
```

`--stdout` 和 `--output` 互斥，并且只允许恰好一个 JSON 类格式（`json`、`api-surface`、`coverage`、`symbol-index`）。诊断写入 stderr，所以重定向后的文件仍然是单个 JSON。

## 生成 API 快照

用 `api-surface` 保存公开 API 的稳定快照，用来比较版本变化或在检查时锁定 API：

```bash
cjdoc generate --project . --format api-surface --stdout > api-surface.json
```

也可以不用 `--stdout`，产物会写到 `target/doc/api-surface/api-surface.json`。snapshot 里包含声明、可见性、签名、参数默认值、文档内容等信息。cjdoc 只接受由当前版本生成的 snapshot；格式不匹配的文件会被拒绝。

## 生成覆盖率报告

```bash
cjdoc generate --project . --format coverage
```

生成两个文件：

- `target/doc/coverage/coverage.json`：符号、参数、返回值、异常、示例、弃用和文档链接的统计。
- `target/doc/coverage/quality.json`：按可见范围统计的质量报告，以及命中“摘要只是重复名字”等模板规则的明细。

`--stdout` 只输出 `coverage.json` 的内容。启用多语言时还会生成 `coverage/translations.json`。

覆盖率可以直接作为门槛：在 `cjdoc.toml` 的 `[coverage]` 中写阈值后，`generate` 和 `check` 都会检查，低于阈值时退出码为 `1`；`check` 还可以用命令行临时指定：

```bash
cjdoc check --project . --min-symbol-coverage 80 --min-parameter-coverage 70
```

阈值范围是 0 到 100。质量规则的判定方式见 [文档质量检查](documentation-quality.md)，配置写法见 [配置参考](configuration.md)。

## 生成符号索引

```bash
cjdoc generate --project . --format symbol-index
```

产物是 `target/doc/symbol-index/symbol-index.json`，面向需要按符号做索引的工具或代理；HTML 里也带一份同类索引。需要细节时见 [高级用法](advanced-usage.md)。

## 控制显示范围与生成行为

### 选择 audience

| 值 | 可见声明 |
|---|---|
| `external`（默认） | `public`、`protected` |
| `package` | 除 `private` 外的声明 |
| `all` | 全部声明 |

例如查看内部 API：

```bash
cjdoc generate --project . --format html --audience all
```

### 调整 lint 级别

`--lint-profile` 控制生成和检查时的文档质量诊断：

- `off`：关闭 lint 质量诊断。
- `standard`（默认）：报告文档质量规则。
- `strict`：更严格的 lint 级别；发布前可以把 `cjdoc check --deny-warnings` 和它一起用。

具体规则的严重级别可以在 `cjdoc.toml` 的 `[lint]` 里逐条配置，见 [文档质量检查](documentation-quality.md) 和 [配置参考](configuration.md)。

### 条件编译

用 `--cfg NAME=VALUE` 提供条件编译输入，可以重复：

```bash
cjdoc generate --project . --format html --cfg feature=fast
```

是否进入文档由源码里的 `@When` 等条件决定；条件不满足的声明不会出现在文档里。

### 并行与缓存

- `--jobs 1..64` 控制并行解析源码文件的个数，默认 `1`。
- 源码缓存默认放在 `target/cjdoc/cache/source-v11`；用 `--cache-dir <目录>` 换位置，或用 `--no-cache` 关闭缓存。

### 依赖与外部文档

默认不会把 path 依赖和缓存依赖的源码纳入文档。需要更大范围时：

- `--include-path-dependencies`：包含 manifest 中 path 依赖的源码。
- `--include-cached-dependencies`：包含缓存里的依赖源码；`--cjpm-cache <目录>` 可以指定缓存根目录，但必须和本选项一起用。
- `--dependency-source NAME=PATH`：显式指定一个依赖的源码目录，可重复。
- `--build-context`、`--doc-source`、`--doc-inventory-pin`、`--link-language`、`--link-language-fallback`、`--link-compatible`：依赖文档与外部文档链接的高级场景。

完整说明见 [高级用法](advanced-usage.md)。

### 多语言

- `--locale zh-CN|en`：选择单语言读取视图，默认 `zh-CN`。
- `--all-languages`：一次分析并生成各语言的独立目录，需要先在 `cjdoc.toml` 中配置 `[i18n]`。
- `--require-language zh-CN|en`：可重复；把指定语言的翻译覆盖率门槛设为 100%。

标签写法、翻译配对和缺译策略见 [多语言文档](i18n.md)。

## 添加 GitHub 源码链接

如果项目托管在 GitHub，希望声明页出现 “View source” 链接，生成时提供仓库信息：

```bash
cjdoc generate --project . --format html \
  --repository-url https://github.com/<owner>/<repo> \
  --repository-revision <commit-or-ref> \
  --repository-root .
```

- `--repository-url` 和 `--repository-revision` 必须成对提供；仓库 URL 是 `https://github.com/owner/repo`，revision 可使用已有的 commit 或 ref。
- `--repository-root` 可选，表示仓库根目录；默认取 `--project` 的目录，当项目位于仓库子目录时才需要显式指定。它要求前两个选项同时提供。
- 这些选项只用于 `generate`（`serve` 预览也接受，用于生成同样的链接），采用旧的单仓声明模式，不核对回执或捕获源码字节。
- 无法确认源码文件位于登记仓库内时，页面会省略源码链接，不会生成猜测地址。要为多个源码根配置仓库映射和 caller-pinned receipt，见[配置参考](configuration.md)。

显式的 `[[source.repositories]]` 配置启用严格登记模式：未登记的文件不会回退到上述单仓选项。Receipt 的格式、SHA-256 核对方式和信任边界见[配置参考](configuration.md)。

重导出可能有两个不同的源码位置：`查看源码` 指向目标声明，`暴露位置` 指向当前模块中的重导出行。它们分别依据各自的文件来源记录和 source range 生成链接，不互相替代；任一位置没有可用链接时只省略该链接。

## 检查文档问题

```bash
cjdoc check --project .
```

`check` 只扫描源码、解析引用和运行文档规则，不生成 HTML、Markdown 或 JSON。诊断格式如下，第一行是严重级别、诊断码和消息，第二行是源码位置：

```text
<severity>[<CJDOC 诊断码>]: <消息>
 --> <源文件路径>:<行>:<列>
```

需要把 warning 也当作失败时：

```bash
cjdoc check --project . --deny-warnings
```

### 退出码

`generate` 和 `check` 的退出码：

| 退出码 | 含义 |
|---:|---|
| `0` | 没有被当前规则拒绝的诊断 |
| `1` | 存在 error，或 warning 被 `--deny-warnings` 提升；覆盖率和 API 基线门槛未通过也返回 1 |
| `2` | 命令行参数错误，或读取输入文件、写入输出等操作失败 |

### 用 API 快照锁定现有 API

`check` 可以拿一份 API 快照作为基线，要求当前 API 与基线完全一致：

```bash
cjdoc generate --project . --format api-surface --stdout > api-surface.json
cjdoc check --project . --api-surface-baseline api-surface.json
```

任何差异都会让检查失败，包括新增 API、签名变化和文档内容变化。适合在发布后锁定已公开的 API；如果只想检查破坏性变化，用下一节的 `diff`。基线快照的所属项目、audience 和条件编译配置必须与当前检查一致。

### 覆盖率门槛

见上文“生成覆盖率报告”。`check` 可以直接用 `--min-symbol-coverage` 和 `--min-parameter-coverage` 指定临时门槛，`cjdoc.toml` 里的 `[coverage]` 阈值对 `generate` 和 `check` 都生效。

## 比较两个 API 快照

先分别生成两个版本的快照：

```bash
cjdoc generate --project . --format api-surface --stdout > api-surface-old.json
cjdoc generate --project . --format api-surface --stdout > api-surface-new.json
```

再比较：

```bash
cjdoc diff --baseline api-surface-old.json --current api-surface-new.json --format text --deny-breaking-api
```

也可以把两个文件直接放在命令后面：

```bash
cjdoc diff api-surface-old.json api-surface-new.json
```

- `--format text`（默认）打印摘要和逐条变化；`--format json` 输出机器可读的报告。
- 每条变化会归类为 `breaking`、`potentially-breaking`、`additive`、`documentation-only`、`metadata-only` 或 `unchanged`。
- 默认只报告差异并返回 `0`。`--deny-breaking-api` 遇到 `breaking` 返回 `1`；`--deny-potentially-breaking-api` 遇到可能破坏兼容性的变化返回 `1`。两个选项可以同时使用。
- 参数错误、快照读取失败或两个快照不属于同一项目、同一 audience、同一条件编译配置时返回 `2`。
- 两个快照都必须由当前版本的 cjdoc 生成。

## 从已有 JSON 重新生成

如果已经有 `docs.json`，只改渲染或分发产物时不需要重新扫描源码：

```bash
cjdoc render \
  --input target/doc/docs.json \
  --format html \
  --format markdown \
  --output target/doc-rendered
```

- `--input` 必填，只接受当前格式的 `docs.json`；旧版本格式会被拒绝。
- `--format` 可重复，可选 `json`、`markdown`、`html`、`api-surface`、`coverage`、`symbol-index`；不写时默认 `json`。
- 不写 `--output` 时输出到当前目录下的 `target/doc`。
- `--stdout` 规则和 `generate` 相同：只能配合恰好一个 JSON 类格式。
- 还支持 `--locale`、`--all-languages`、`--doc-version`（要求 HTML）、`--agent-full`（要求 HTML）。
- 输出目录必须不存在，或此前由 cjdoc 管理。只有后者能配合 `--force-owned` 接管被修改的已登记产物；预创建或含无关文件的目录不能用 `--force-owned` 接管，请换一个新目录。

当前 Doc IR wire 是 `cjdoc.doc-ir/18`，decoder 只接受当前版本，不迁移旧 JSON。旧 `docs.json` 需要从原始源码重新运行 `cjdoc generate` 生成 v18，再交给 `render`；没有可用源码时没有受支持的旧快照迁移路径。v18 同步使用 `cjdoc.declaration/3`、`cjdoc.page/2` 和 `cjdoc.query-result/4`；`cjdoc.query-request/3`、`cjdoc.search-index/11` 与 `cjdoc.search-contract/2` 保持不变。维护者 wire 清单见 [Doc IR、schema 与 golden](maintainer/doc-ir.md)。

例如，从源码先重新捕获 v18，再从新快照渲染 HTML：

```bash
cjdoc generate --project . --format json --output target/doc-v18
cjdoc render --input target/doc-v18/docs.json --format html --output target/doc-v18-html
```

## 本地预览

```bash
cjdoc serve --project .
```

- 启动后访问 `http://127.0.0.1:8080/`；用 `--port <端口>` 换端口，用 `--open` 自动打开浏览器。
- 服务只监听本机 `127.0.0.1`。
- 修改 `.cj`、`.md`、`cjpm.toml` 或 `cjdoc.toml` 后会自动重新生成，刷新页面即可看到变化。
- 重建失败时会保留上一次成功的站点，终端会提示失败。
- 状态接口 `GET /__cjdoc/status.json` 返回最近一次构建的状态、构建次数和错误信息。
- 服务运行期间会一直占用终端，按 `Ctrl+C` 停止。

`serve` 实际执行的是 HTML 生成，输出目录与 `generate` 相同（默认 `target/doc`）。

## 常见故障排查

### 提示找不到 cjdoc 命令

可执行文件所在目录没有加入当前终端的 `PATH`。加入后重新打开终端，再运行 `cjdoc --version`。Windows 还需要确认放的是 `cjdoc.exe`。

### 启动时报缺少仓颉运行时库

仓颉 SDK 没有安装，或者 SDK 的环境脚本没有在当前终端生效。安装 SDK，执行 SDK 自带的 `envsetup` 后重新打开终端，确认 `cjc -v` 可用。

### 提示项目必须包含 `cjpm.toml`

`--project` 指向了 `src/` 之类的子目录。这会报告 `project must contain cjpm.toml` 的 error 诊断，命令退出码为 `1`。把命令改成指向项目根目录：

```bash
cjdoc generate --project /path/to/my-project --format html
```

### 页面里没有我的声明

依次确认：声明是 `public` 或 `protected`；注释使用 `/** ... */` 并紧贴声明；命令指向正确的项目。需要看内部声明时加 `--audience all`。

### 修改注释后页面没有变化

重新运行生成命令，确认打开的是同一输出目录下的 `target/doc/html/index.html`，然后刷新页面。

### 生成结果被标记为不完整（partial）

说明部分源码或引用没有完整解析。先看终端诊断里的源码位置，再确认是否需要补充 `--cfg` 条件编译输入，或是否要把依赖源码纳入文档。cjdoc 会保留能解析的部分，不会把不确定的信息标成已解析。

### 输出目录报所有权或冲突错误

不要预先创建 `target/doc`，也不要把含无关文件的目录直接交给 cjdoc。换一个新的输出目录；只有此前由 cjdoc 管理过的目录，才能用 `--force-owned` 接受其中被修改的已登记产物。由 cjdoc 管理过的目录可以直接重复使用。

### 示例检查失败

- 确认 `cjc` 在 `PATH` 中。
- 示例只写可以放进函数体的代码片段，`import` 写在示例所属的源码文件里。
- 检查 `@example` 指令拼写和冲突；指令问题报告 `CJDOC3033`。
- 带 `{run}` 的示例在 macOS 等无法建立内存限制的平台上不能运行，会报告 `CJDOC3074`。
- 固定了结果但没真正检查会报告 `CJDOC3070`，说明示例被跳过（例如超过 256 个的上限）。

### 多语言配置报错

启用 `[i18n]` 时必须写 `default-language`，否则命令以退出码 `2` 报错（`CJDOC3105`）；`[i18n].languages` 不能为空。缺译是否导致失败由 `missing-translation` 和翻译覆盖率阈值决定，见 [多语言文档](i18n.md)。

### 命令报参数错误（退出码 2）

多数是选项组合冲突或输入文件不存在，例如同时用 `--stdout` 和 `--output`、只用 `--doc-version` 却没有 `--format html`、`--repository-url` 没配 `--repository-revision`。错误信息会附上用法；也可以运行 `cjdoc --help` 查看。

## 命令速查

### 命令一览

| 命令 | 作用 |
|---|---|
| `cjdoc --help` / `cjdoc -h` | 打印用法。 |
| `cjdoc --version` | 打印 `cjdoc 0.7.6`。 |
| `cjdoc generate` | 扫描源码并生成 HTML、Markdown、JSON 等产物。 |
| `cjdoc check` | 只检查文档问题，不生成产物。 |
| `cjdoc diff` | 比较两个 API 快照。 |
| `cjdoc render` | 从已有 `docs.json` 重新生成产物。 |
| `cjdoc serve` | 本地预览，修改源码后自动重建。 |
| `cjdoc versions compose` | 把多个版本的 HTML 目录合并成一个带版本切换的站点。 |
| `cjdoc schema <name>` | 输出内置结构定义；`cjdoc schema list` 列出可用名称。 |

### 生成、检查与渲染的常用选项

| 选项 | 适用 | 默认 | 说明 |
|---|---|---|---|
| `--project <目录>` | `generate`、`check`、`serve` | `.` | 项目根目录。 |
| `--format <格式>` | `generate`、`render` | `json` | `json`、`markdown`、`html`、`api-surface`、`coverage`、`symbol-index`；可重复。 |
| `--output <目录>` | `generate`、`render` | `target/doc`（`render` 为当前目录下） | 输出目录，与 `--stdout` 互斥。 |
| `--stdout` | `generate`、`render` | 关闭 | 把单个 JSON 类产物写到标准输出。 |
| `--force-owned` | `generate`、`render` | 关闭 | 接管此前由 cjdoc 管理过的输出目录，并覆盖被修改的已登记产物。 |
| `--audience <值>` | `generate`、`check` | `external` | `external`、`package` 或 `all`；不会从 `docs.json` 剔除内部声明。 |
| `--lint-profile <值>` | `generate`、`check` | `standard` | `off`、`standard` 或 `strict`。 |
| `--jobs <1..64>` | `generate`、`check` | `1` | 并行解析源码文件的个数。 |
| `--cfg NAME=VALUE` | `generate`、`check` | 无 | 条件编译输入，可重复。 |
| `--check-examples` | `generate`、`check` | 关闭 | 编译校验示例，带 `{run}` 的还会运行。 |
| `--deny-warnings` | `generate`、`check` | 关闭 | 把 warning 也当作失败。 |
| `--api-surface-baseline <文件>` | `generate`、`check` | 无 | 要求当前 API 与快照完全一致。 |
| `--min-symbol-coverage <0..100>` | `generate`、`check` | 无 | 符号文档覆盖率下限。 |
| `--min-parameter-coverage <0..100>` | `generate`、`check` | 无 | 参数文档覆盖率下限。 |
| `--locale zh-CN\|en` | `generate`、`render` | `zh-CN` | 单语言读取视图。 |
| `--all-languages` | `generate`、`render` | 关闭 | 生成各语言独立目录，与 `--locale`、`--stdout` 冲突。 |
| `--require-language <语言>` | `generate`、`check` | 无 | 要求指定语言的翻译覆盖率达到 100%，可重复。 |
| `--doc-version <版本>` | `generate`、`render` | 无 | 文档版本标签，要求 `--format html`。 |
| `--agent-full` | `generate`、`render`、`serve` | 关闭 | 生成完整代理文本产物，生成/渲染时要求 `--format html`。 |
| `--validation-report <文件>` | `generate`、`render` | 无 | 发布已有 JSON 验证报告，不执行检查；要求 HTML 目录输出，不允许 stdout。 |
| `--api-diff-report <文件>` | `generate`、`render` | 无 | 发布已有 API diff，保留双输入/缺失绑定状态；要求 HTML 目录输出。 |
| `--repository-url <URL>` | `generate`、`serve` | 无 | GitHub 仓库根地址，必须和 `--repository-revision` 成对。 |
| `--repository-revision <rev>` | `generate`、`serve` | 无 | 源码版本，必须和 `--repository-url` 成对。 |
| `--repository-root <目录>` | `generate`、`serve` | 项目目录 | 仓库根目录，要求前两个选项同时存在。 |
| `--stdlib-doc-version <版本>` | `generate` | 观察到的标准库版本或 `1.2.0` | 标准库文档链接版本。 |
| `--stdlib-doc-base-url <URL>` | `generate` | 内置地址 | 自定义标准库文档根，必须 HTTPS 且以 `/libs/std` 结尾。 |
| `--include-path-dependencies` | `generate`、`check` | 关闭 | 包含 path 依赖源码。 |
| `--include-cached-dependencies` | `generate`、`check` | 关闭 | 包含缓存依赖源码。 |
| `--dependency-source NAME=PATH` | `generate`、`check` | 无 | 显式依赖源码目录，可重复。 |
| `--cjpm-cache <目录>` | `generate`、`check` | 无 | 依赖缓存根目录，需要配合 `--include-cached-dependencies`。 |
| `--cache-dir <目录>` | `generate`、`check`、`serve` | `target/cjdoc/cache/source-v11` | 源码缓存目录。 |
| `--no-cache` | `generate`、`check`、`serve` | 关闭 | 不使用源码缓存。 |
| `--semantic source\|chir` | `generate`、`check` | `source` | 解析后端；`chir` 需要额外 worker，属于高级用法。 |
| `--cjc <可执行文件>` | `generate`、`check` | `cjc` | 指定编译器，需要 `--semantic chir`。 |
| `--chir-worker <可执行文件>` | `generate`、`check` | 无 | CHIR worker，需要 `--semantic chir`。 |
| `--chir-import-path <目录>` | `generate`、`check` | 无 | CHIR 导入路径，需要 `--semantic chir`，可重复。 |
| `--highlight-adapter <绝对路径>` | `generate`、`check` | 无 | 外部高亮适配器，必须和 `--highlight-node` 同时提供。 |
| `--highlight-node <绝对路径>` | `generate`、`check` | 无 | 外部高亮运行时，必须和 `--highlight-adapter` 同时提供。 |
| `--build-context <文件>` | `generate`、`check` | 无 | 目标项目的构建记录。 |
| `--doc-source <目录或清单>` | `generate`、`check` | 无 | 外部文档来源，可重复。 |
| `--doc-inventory-pin PATH=SHA256` | `generate`、`check` | 无 | 固定外部文档清单，可重复。 |
| `--link-language <语言>` | `generate`、`check` | 无 | 外部文档链接语言。 |
| `--link-language-fallback` | `generate`、`check` | 关闭 | 允许回退到默认语言的外部链接。 |
| `--link-compatible` | `generate`、`check` | 关闭 | 接受兼容但非精确的外部链接。 |
| `--input <文件>` | `render` | 无（必填） | 要重新渲染的 `docs.json`。 |

`--semantic chir`、外部高亮和外部文档相关的选项属于高级场景，用法见 [高级用法](advanced-usage.md)。

### `check` 的选项

`check` 接受上表中“适用”列包含 `check` 的选项；它只执行检查，不写生成产物。告警、API 基线与覆盖率门槛选项也可用于 `generate`，并非 `check` 独有。

`check` 不接受 `--format`、`--output`、`--stdout`、`--locale`、`--force-owned`、`--all-languages`，以及仓库链接和渲染相关的选项。

### `diff` 的选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `OLD NEW` 或 `--baseline OLD --current NEW` | 无（必填） | 两份 API 快照。 |
| `--format text\|json` | `text` | 输出文本报告或 JSON 报告。 |
| `--deny-breaking-api` | 关闭 | 有 `breaking` 变化时返回 1。 |
| `--deny-potentially-breaking-api` | 关闭 | 有 `potentially-breaking` 变化时返回 1。 |

### `serve` 的选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--project <目录>` | `.` | 项目根目录。 |
| `--port <端口>` | `8080` | 监听端口。 |
| `--open` | 关闭 | 启动后打开浏览器。 |
| `--agent-full` | 关闭 | 同时生成完整代理文本产物。 |

### `versions compose` 的选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--version ID=PATH` | 无（必填） | 一个版本的本地 HTML 目录（含 `index.html`），可重复。 |
| `--output <目录>` | 无（必填） | 组合结果输出目录。 |
| `--latest ID` | 第一个版本 | 标记为最新版本。 |
| `--label ID=TEXT` | 版本 ID | 版本显示名。 |
| `--channel ID=TEXT` | `unspecified` | 版本渠道标记。 |
| `--status ID=TEXT` | `published` | 版本状态标记。 |
| `--base-path ID=PATH` | 版本 ID | 该版本在输出站点里的路径前缀。 |
| `--release ID=TEXT` | 无 | 版本发布信息，按纯文本显示在版本卡片上，不生成链接。 |
| `--diff ID=PATH` | 无 | 该版本对应的 API diff JSON 报告。 |
| `--force-owned` | 关闭 | 接管此前由 cjdoc 管理过的输出目录。 |

多版本文档的完整做法见 [高级用法](advanced-usage.md)。

## 延伸阅读

- [高级用法](advanced-usage.md)：多格式组合、workspace 与依赖、缓存与并行、条件编译、多版本文档、面向 AI 代理的产物、自动化检查接入。
- [逐声明读取、查询与 MCP](agent-reading.md)：固定快照、API/文档身份、静态分片、章节预算、报告与 MCP 配置；读取不自动编译或重建。
- [配置参考](configuration.md)：`cjdoc.toml` 全部配置键。
- [概念页与指南](guides.md)：把项目 Markdown 组织成概念文档并与 API 绑定。
- [多语言文档](i18n.md)：中英文作者正文、翻译配对与覆盖率。
- [文档质量检查](documentation-quality.md)：质量规则与报告。
