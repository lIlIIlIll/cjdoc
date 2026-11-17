# 文档注释参考

仓颉声明注释里可用的标签、属性、示例指令、分组与多语言写法，以及指南 Markdown 与 API 的绑定语法。生成流程见[生成与发布](../how-to/generate-and-publish.md)，示例检查的操作步骤见[检查文档示例](../how-to/check-examples.md)，配置项见[配置参考](configuration.md)。

## 注释识别

- 只有声明前紧邻的 `/** ... */` 绑定到该声明；`//` 与 `/* ... */` 不生成文档。
- 正文按 Markdown 解析。第一段顶层普通段落是摘要，其余顶层普通段落是详细说明；只有标题、列表、引用、代码块等非段落块时，它们全部留在详细说明里，不会提升为摘要。
- 结构化 `@...` 标签必须位于顶层 Markdown 段落。代码围栏、缩进代码、列表或引用里的同样文字只是正文。
- 单段标签的说明可以换行续写，空行结束该段并回到正文。`@group`、`@tag` 是单行元数据，示例与语言限定字段各有自己的连续内容规则。
- 不认识的 `@...` 保留为普通正文，不要依赖拼错的标签被解释。
- 默认只展示 `public`、`protected` 声明；`internal`、`private` 由 `--audience` 选择，见[状态与限制](states-and-limits.md#可见范围与快照身份)。

## 支持的标签

| 标签 | 内容 | 规则 |
|---|---|---|
| `@param name 说明` | 参数说明 | 名称必须与声明中的真实参数名一致，每个参数一项；不存在报 `CJDOC3109` |
| `@return 说明` | 返回值说明 | 每个注释只支持一个 `@return`，重复报 `CJDOC3003` |
| `@throws Type 说明` | 可能抛出的异常 | 可重复；同一声明重复写同一异常报 `CJDOC3022`；未写说明报 lint `missing-throws` |
| `@see 目标 说明` | 相关声明引用 | 目标无法唯一解析时报 `CJDOC3008` 或 lint 规则 |
| `@since 版本` | 引入版本 | 2–4 段数字，如 `0.1.0`；其他形式报 lint `invalid-since-version` |
| `@deprecated 说明` | 弃用标记与原因 | 无说明仍保留弃用状态，但报 lint `deprecated-without-message` |
| `@author 名称` | 作者 | 可重复 |
| `@version 版本` | 版本元数据 | 不参与多语言配对 |
| `@example [标题] {指令}` | 示例标题、指令与随后的代码围栏 | 见[示例](#示例) |
| `@precondition`、`@postcondition`、`@invariant`、`@performance`、`@state`、`@concurrency`、`@platform`、`@compatibility`、`@error` | 行为契约 | 说明为空时报 `CJDOC3043` |
| `@group id 标题` | 展示分组 | 每个声明最多一个，见[分组与标签](#分组与标签) |
| `@tag id` | 声明级分类标签 | 可重复，见[分组与标签](#分组与标签) |
| `@note`、`@warning`、`@danger` | 作者标记的提示块 | 见[提示标签](#提示标签) |
| `@summary`、`@description` | 显式指定摘要、详细说明 | 需要 `default-language`，见[多语言注释](#多语言注释) |

行为契约描述作者记录的内容，不是编译器证明、测试回执或兼容性保证。`@since`、`@version`、`@author`、`@group`、`@tag` 是共享元数据，不能加语言限定。

### 宏声明与宏包裹的源码

`public macro` 使用与函数相同的参数、返回与示例标签；签名取自源码，并在 HTML 的宏分组中展示。对 `@Derive[Equatable]` 之类宏包裹的声明，绑定的是输入里的源码声明和成员，嵌套宏同样适用。

cjdoc 不执行宏。宏调用保留在 `macroInvocations`，由 `CJDOC1009` 说明生成成员未知，文档为 `partial`；无法还原为源码声明的输入进入 `unsupportedDeclarations`。宏生成的方法不进入 API 清单，源码已有声明仍可搜索、链接与离线查询。

### 完整的 `clamp` @throws 示例

完整公开声明文件，保存为 `src/clamp.cj`；不含 `main`，可与其它文件一起编译。要发布双语注释，项目需在自己的 `cjdoc.toml` 里设置 `default-language = "zh-CN"` 与 `languages = ["zh-CN", "en"]`，两种语言的异常条目用 `invalid-bounds` 显式配对。

```cangjie
package docdemo

/**
 * @summary 将 value 限制在闭区间 [lower, upper] 内。
 * @summary[lang=en] Clamp value to the closed interval [lower, upper].
 *
 * @description 对合法边界，返回不小于 lower 且不大于 upper 的值；等界时只返回该边界。
 * @description[lang=en] For valid bounds, return a value within the interval; when the bounds are equal, return that boundary.
 *
 * @param value 要限制的整数。
 * @param[lang=en] value The integer to clamp.
 * @param lower 闭区间下界。
 * @param[lang=en] lower The lower bound of the closed interval.
 * @param upper 闭区间上界。
 * @param[lang=en] upper The upper bound of the closed interval.
 * @return 闭区间内的限制结果。
 * @return[lang=en] The clamped value within the closed interval.
 * @throws[id=invalid-bounds] IllegalArgumentException 当 lower 大于 upper 时抛出。
 * @throws[lang=en,id=invalid-bounds] IllegalArgumentException Thrown when lower is greater than upper.
 */
public func clamp(value: Int64, lower: Int64, upper: Int64): Int64 {
    if (lower > upper) {
        throw IllegalArgumentException("lower must be less than or equal to upper")
    }
    if (value < lower) { return lower }
    if (value > upper) { return upper }
    value
}
```

`cjdoc check` 会报告实际发现的问题：异常名没有唯一绑定时可能出现 `CJDOC3109`，类型只有源码拼写、没有语义身份时可能出现 `CJDOC3041`；默认 CHIR 能补充 `Int64` 等类型信息。把区间外的 `value` 截到最近边界、`lower == upper` 时返回该边界、`lower > upper` 时抛出，是这段代码的实际行为。要自己验证这些边界，见[验证一个边界条件](../how-to/review-contracts.md#验证一个边界条件)。

## 分组与标签

### `@group`：展示分组

每个声明最多一个 `@group`。ID 是 1–64 个 ASCII 字母、数字、`-`、`_`，大小写敏感；内联标题是 1–256 UTF-8 字节的单行非空白纯文本，不得含 C0/DEL 控制字符。

```cangjie
/**
 * 将文本写入输出。
 * @group 20-serialization 序列化
 */
public func writeText(): Unit {}
```

`@group <id>` 可以省略标题，但必须能在同一 module、package、owner scope 的 `[metadata.groups]` 里找到定义，否则报 `CJDOC3137`，该分组不生效：

```text
error[CJDOC3137]: @group shorthand requires a matching metadata.groups definition for its declaration container
```

非法或重复的内联分组报 `CJDOC3130`；同一 scope 中相同 ID 的内联标题互相冲突报 `CJDOC3131`；`@group[lang=...]` 报 `CJDOC3112`。

不同 module/package/原始 owner 中的同名 ID 是不同分组。排序规则：显式 `order` 升序在前，未指定顺序的组随后，未分组声明最后。标题只影响显示，不改变 API 身份、可见性、兼容性分类或 SymbolId。配置表与 scope 诊断见[配置参考](configuration.md)。

### `@tag`：分类标签

每行只写一个 ID，多个不同标签可以附在同一声明：

```cangjie
/**
 * 以流式方式发送数据。
 * @group 20-serialization 序列化
 * @tag streaming
 * @tag extension-point
 */
public func sendStream(): Unit {}
```

ID 为 1–64 个 ASCII 字母、数字、`-`、`_`，大小写敏感。同一注释内重复 ID 按集合去重，输出按 ID 的 UTF-8 字节排序。非法字符、空 ID、超长 ID 或多余参数报：

```text
error[CJDOC3132]: @tag requires one ASCII identifier (1-64 letters, digits, '-' or '_') with no extra arguments
```

非法项不进入标签集合，但不会删除该声明。`@tag` 不能接续正文，也不能加语言限定（`@tag[lang=en]` 报 `CJDOC3112`）。

标签只属于写了该注释的声明，不从包、类型、基类、扩展或重载族继承。标签不是行为契约，不进入契约质量分或翻译覆盖率分母，也不改变源码/API 身份。配置里的标题只用于显示；查询、HTML 搜索与 facets 都按大小写敏感的完整 ID 匹配，多个 ID 取交集。

## 提示标签

只识别小写的 `@note`、`@warning`、`@danger`，且必须在顶层 Markdown 段落。标签之后的连续顶层普通文本行构成提示正文；空行、下一条顶层 `@...` 或注释结束会结束提示，其后的普通说明需要用空行隔开。列表、引用、代码块里的同样文字，以及 `@Warning`、`@noteish`，都按普通正文处理。

属性只能按以下形式和顺序书写，括号内不加空格或引号：

```text
@warning
@warning[id=stale-cache]
@warning[lang=en]
@warning[lang=en,id=stale-cache]
```

作者 ID 为 1–64 ASCII 字节，首字符必须是小写 `a-z`，其余只能是小写字母、数字、`_`、`-`。

| 情况 | 结果 |
|---|---|
| 属性结构错误（缺 `]`、含空格或引号、多余属性） | `CJDOC3115` |
| ID 形状不合法 | `CJDOC3116` |
| 语言结构错误 | `CJDOC3102` |
| 不支持的语言 | `CJDOC3103` |
| 同一语言重复 ID，或同一 ID 跨提示等级复用 | `CJDOC3118`，冲突内容保留为 `unpaired`，不改等级 |
| 提示为空，或只有 Markdown 引用定义、没有可见正文 | `CJDOC3117`，保留原文但不渲染空提示块 |

没有 ID 的条目不会按位置、正文或「唯一候选」配对。HTML 输出静态、带可见等级标题的提示区域；正文走安全 Markdown renderer，不注入 HTML，不产生弹窗、`role="alert"` 或 live region。API 侧提示只由注释标签创建；指南 Markdown 引用块里的提示标记属于概念页输入，规则见[指南 Markdown 与 API 绑定](#指南-markdown-与-api-绑定)。

## 示例

`@example` 的标题可省略。示例正文里一个或多个 `cangjie` 围栏按顺序合成一个示例，直到下一个受支持的顶层标签结束；围栏里形似标签的文字属于示例内容。HTML 与 Markdown 会显示示例，但默认不编译、不运行——检查必须显式加 `--check-examples`。

```cangjie
/**
 * 返回两个数值的和。
 * @param left 左操作数。
 * @param right 右操作数。
 * @return 两数之和。
 * @example 基本用法 {run}
 * ```cangjie
 * println(add(1, 2))
 * ```
 * ```output
 * 3
 * ```
 */
public func add(left: Int64, right: Int64): Int64 {
    left + right
}
```

指令写在标题后的 `{...}` 里：

| 指令 | 作用 |
|---|---|
| `must-pass` | 要求示例实际编译通过 |
| `must-fail` | 要求编译失败，且错误归因于示例文件本身 |
| `error="文本"` | 与 `must-fail` 同用，要求诊断包含该文本 |
| `run` | 编译通过后作为程序运行，要求退出码为 0 |
| `flags="..."` | 追加限定的 `cjc` 编译选项，白名单见下 |

指令名区分大小写、不可重复；`must-pass` 与 `must-fail` 互斥，`run` 不能与 `must-fail` 同用，`error=` 必须搭配 `must-fail`。违规、未知指令或非白名单参数报 `CJDOC3033`，该示例不编译：

```text
error[CJDOC3033]: @example '冲突' has invalid directives: 'must-pass' and 'must-fail' conflict (accepted: must-pass, must-fail, run, error="…", flags="…")
```

`flags` 白名单只有：`--cfg NAME=VALUE`（用户配置键）、`-Woff GROUP` / `-Won GROUP`（`all`、`unused`、`unused-main`、`deprecated`、`unsupport-compile-source`、`package-import`、`parser`、`semantics`、`interpreter`、`apilevel-check`）、`--int-overflow throwing|wrapping|saturating`，以及单独的 `--experimental`、`-O0`、`-O1`、`-O2`、`-Os`、`-Oz`。输入/输出路径、依赖、import 与包配置不由指令控制；需要的 import 必须写在所属源码文件里，代码片段只写函数体内的语句。

每个示例最多一个 `output` 围栏，且必须与 `run` 同用；比较时统一换行符并忽略首尾空行。示例包在无参数 `main` 里执行，不能使用 `args`。

| 边界或结果 | 报告 |
|---|---|
| 单次运行 10 秒 | `CJDOC3073` |
| stdout、stderr 各最多 64 KiB | `CJDOC3075` |
| 内存最多 2048 MiB；无法建立限制时拒绝运行 | `CJDOC3074` |
| 单次检查最多 256 个示例 | 超出部分不检查 |
| 示例自身编译失败 | `CJDOC3030` |
| 失败不能归因于示例（如所属源码上下文无法编译） | `CJDOC3031` |
| 未真正检查或受限跳过 | `CJDOC3070` |
| 运行退出码非零 | `CJDOC3071` |
| 实际 stdout 与 `output` 不一致 | `CJDOC3072`，例如 `output mismatch: expected 3, got 2` |

逐例结果通过诊断与退出码报告，不生成独立结果文件或执行徽章。命令用法见[检查文档示例](../how-to/check-examples.md)。

## 多语言注释

cjdoc 不自动翻译，也不校验译文是否正确、同步或最新；每种语言的正文由作者提供。启用多语言需在项目自己的 `cjdoc.toml` 里配置 `[i18n]`，见[配置参考](configuration.md)。目前只发布 `zh-CN` 与 `en`，语言标签按大小写归一化到这两个值，不推断 `zh-Hans`、`zh-TW`、`en-US` 等别名。

可本地化字段：摘要、详细说明、参数、返回值、异常、引用、弃用、示例，以及九种行为契约。

```cangjie
/**
 * @summary 将 value 限制在区间内。
 * @summary[lang=en] Clamp value to an interval.
 * @param value 待限制的值。
 * @param[lang=en] value The value to clamp.
 * @return 限制后的值。
 * @return[lang=en] The clamped value.
 */
```

语言限定必须紧跟标签名、在同一行，形如 `@param[lang=en] text ...`。`@param` 译文仍要写出真实参数名；语言限定之后的多段说明、列表、表格、引用和围栏都属于该译文。自然语言限定不会改变代码围栏语言或 `{run}` 等示例指令的含义。

`@since`、`@version`、`@author`、`@group`、`@tag` 禁止加 `[lang=...]`，否则报 `CJDOC3112`。普通本地化字段要求所属输入能确定 `default-language`；没有配置却使用普通语言字段或 `@summary`、`@description`、带 ID 的 `@throws` 时报 `CJDOC3105`。workspace 成员没有自有配置时可继承 workspace 根的选项；path/cache 依赖各读自己的语言元数据，不继承根项目默认语言。

### `@throws` 条目身份

`@throws Type 说明` 在异常类型能唯一绑定时可自动配对；不能证明唯一目标时，用显式 ID 指定同一条目的不同语言版本：

```cangjie
/**
 * @throws[id=invalid-bounds] IllegalArgumentException 当 lower 大于 upper 时抛出。
 * @throws[lang=en,id=invalid-bounds] IllegalArgumentException Thrown when lower is greater than upper.
 */
```

ID 只在当前声明的 `@throws` 条目内生效，1–64 字节，首字符小写 `a-z`，其余只能是小写字母、数字、`_`、`-`。属性只接受 `[id=...]` 或 `[lang=...,id=...]`，顺序固定；其他顺序或多余属性被拒绝，ID 形状错误报 `CJDOC3113`。同语言复用同一 ID，或跨语言同 ID 指向不同异常主体/唯一解析目标，报 `CJDOC3114`，两条都保留为独立条目并保留原文。

显式 ID 证明的是两条作者说明互相关联，不证明异常类型链接已解析：源码模式下标准库异常仍可能报 `CJDOC3109`（如上面 `clamp` 例子）。

### 提示的语言配对与回退

提示只支持 `@note`、`@warning`、`@danger`，属性可为空、`[id=x]`、`[lang=en]`、`[lang=en,id=x]`。提示 ID 与 throws ID 字符规则相同但作用域不同：三个提示等级在同一声明内共用一个 ID 命名空间。有 ID 且有效的提示先取请求语言，再取所属输入的默认语言；仍缺时只在存在唯一有效其他语言候选时回退，并标注正文的实际来源。没有有效正文的 ID 变体不能因回退而被算作完成译文。

没有 `[i18n]` 时，普通注释字段按未本地化内容显示；如果注释只有顶层提示标签而没有触发完整本地化的字段，其本地化范围为 `admonitions`，只允许提示使用 `[lang=...]` 与 ID。启用 `[i18n]`，或同一注释里出现普通语言字段、`@summary`、`@description`、带 ID 的 `@throws` 等完整本地化触发项时，范围为 `all`，未限定的正文属于配置的默认语言。

### 译文选择与状态

选择顺序是请求语言、输入默认语言、缺失。显式 `@throws` ID 或提示 ID 在两者都无效时，可从唯一有效的其他语言回退；回退不算完整译文。同语言同字段重复定义时两处都标为 conflict，不以后一条覆盖前一条；引用和 `@throws` 的重复项只有在目标/ID 可证明且每语言唯一时才配对；契约按种类、每语言唯一时配对；示例不按标题、行号或数组位置配对。不能证明时保留为独立条目。

| 诊断 | 含义 |
|---|---|
| `CJDOC3101` | 普通语言头语法错误 |
| `CJDOC3102` | 语言标签结构错误 |
| `CJDOC3103` | 不支持的语言 |
| `CJDOC3104` | 文本语言未列入当前输入的发布集合 |
| `CJDOC3105` | 缺少默认语言 |
| `CJDOC3106` | 单语言同字段重复 |
| `CJDOC3107` | 条目不能唯一配对 |
| `CJDOC3108` | 缺译、回退、空译、冲突、未知来源或未配对；`missing-translation = "deny"` 时升级为 error |
| `CJDOC3109` | 参数不存在，或引用/throws 目标无法唯一绑定 |
| `CJDOC3110` | 页面 ID/语言或章节映射问题 |
| `CJDOC3111` | 翻译覆盖率低于门槛 |
| `CJDOC3112` | 共享元数据加了语言限定 |
| `CJDOC3113` | throws ID 非法 |
| `CJDOC3114` | throws ID 冲突 |
| `CJDOC3115` | 提示属性语法错误 |
| `CJDOC3116` | 提示 ID 非法 |
| `CJDOC3117` | 空提示 |
| `CJDOC3118` | 提示 ID 同语言重复或跨等级冲突 |

字段级状态词（`complete`、`fallback`、`empty-fallback` 等）见[状态与限制](states-and-limits.md#多语言与诊断状态)。

项目首页只有一个 `index` 文件，不按语言 ID 配对，其他语言阅读时显示同一内容并标记来源；指南页面由同 `id`、不同 `language` 配对，章节通过同一逻辑键映射到各自标题的实际锚点，见[发布多语言页面](../tutorials/publish-languages.md)。

## 指南 Markdown 与 API 绑定

概念页（首页、模块页、包页、指南）的 Markdown 支持标题、段落、列表、表格、引用、代码块、行内代码、强调、链接与本地栅格图片。原始 HTML 按文本处理，不注入页面；独占一行的 `cjdoc-bind` 标记具有下述特殊含义。指向其他已登记概念页源文件的相对链接映射成输出路由，同页 fragment 映射成实际锚点；指向未登记文件的相对链接保持原样，发布前由作者确认目标随站点提供。

PNG、JPEG、GIF、WebP、AVIF 可在安全捕获后随站点发布；远程图片 URL 不会自动下载。SVG 不是受支持的本地图片输入格式。格式与大小边界见[状态与限制](states-and-limits.md#能力边界)。

### Markdown 提示块

只有 `[!NOTE]`、`[!WARNING]`、`[!CAUTION]` 会分别成为 note、warning、danger。标记必须独占顶层引用块首段的第一条物理行，后面要有可见正文：

```markdown
> [!NOTE]
> 名字中的空白会被原样保留。

> [!WARNING]
> 发布前核对输入版本，避免混用旧快照。

> [!CAUTION]
> 删除站点前先确认备份和输出所有权。
```

`> [!WARNING] 正文` 不满足独占规则；`[!DANGER]`、`[!TIP]`、`[!IMPORTANT]`、拼写错误，以及列表或嵌套引用中的标记，都保留为普通引用。只有标记或只有引用定义而没有正文时，保留普通引用并报 `CJDOC3117`，诊断指向指南文件。页面其余内容照常生成。

HTML 用静态提示区域和可见的本地化等级标题，正文仍走安全 Markdown renderer，不产生 alert、live region 或弹窗。Markdown 输出保留引用形式，danger 对应 `[!CAUTION]`。这与注释里的 `@note` 等标签是两套不同输入。

### 精确关联 API 与重载

标记独占一行，且不能出现在代码块或缩进代码里：

```markdown
<!-- cjdoc-bind target="docdemo.greet" -->
```

| 属性 | 匹配规则 |
|---|---|
| `target="docdemo.greet"` | 限定名完全相等，不按短名猜目标 |
| `target="id:<稳定 ID>"` | SymbolId 完全相等；从生成的导航索引复制实际 ID |
| `selector="signature:public func greet(name: String): String"` | 与 target 一起精确选择源码声明头，用于区分重载 |
| `language="cangjie"` | 可选记录属性，默认 `markdown`；不是译文配对开关 |

一页可以写多个标记，每页最多 32 个（超出报 `CJDOC2054` 并忽略其余）。找到唯一且受众可见的声明时，标记位置显示「相关 API」与签名；API 反向入口指向标记所在的可证明章节，没有章节证据时回到文章。页面底部可展开全部关联，Markdown 输出在末尾列出。

| 情况 | 诊断 | 结果 |
|---|---|---|
| 找不到目标 | `CJDOC2051` | 页面保留，显示未绑定状态 |
| 目标有歧义 | `CJDOC2052` | 不静默选一个 |
| 同一 target+selector 重复 | `CJDOC2053` | 重复项标为冲突 |
| 当前受众不可见 | `CJDOC2055` | 保留未绑定状态 |
| 标记缺少 target | `CJDOC2056` | 该标记不生效 |

模块页默认读取 `docs/modules/<slug>.md` 并发布为 `concepts/modules/<slug>.html`，缺文件时提供中性占位说明。路由规则、自动页面与章节映射见[配置参考](configuration.md)；导航的实际路由以输出索引为准，不要凭标题推哈希。
