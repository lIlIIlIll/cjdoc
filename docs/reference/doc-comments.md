# 文档注释参考

仓颉声明注释里可用的标签、属性、示例指令、分组与多语言写法，以及指南 Markdown 与 API 的绑定语法。生成流程见[生成与发布](../how-to/generate-and-publish.md)，示例检查的操作步骤见[检查文档示例](../how-to/check-examples.md)，配置项见[配置参考](configuration.md)。

要从源码对照实际页面，打开 [PocketKit 文档注释示例](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/docs/doc-comments.md)；生成 demo-v2 站点后可从首页进入并沿「相关 API」打开对应声明。

## 快速索引

| 你要写 | 用哪个标签 | 详见 |
|---|---|---|
| 参数、返回值、异常 | `@param`、`@return`、`@throws` | [支持的标签](#支持的标签) |
| 版本、作者、弃用、相关声明 | `@since`、`@version`、`@author`、`@deprecated`、`@see` | [支持的标签](#支持的标签) |
| 调用前后条件、状态、并发责任 | 九种行为契约 | [行为契约](#行为契约) |
| 可执行或可核对的代码 | `@example` 与 `cangjie`、`output` 围栏 | [示例](#示例) |
| 注意、警告、危险提示 | `@note`、`@warning`、`@danger` | [提示标签](#提示标签) |
| 页面分组与分类标签 | `@group`、`@tag` | [分组与标签](#分组与标签) |
| 中英文分别写正文 | `[lang=en]` 等语言限定 | [多语言注释](#多语言注释) |
| 指南里嵌入 API 入口 | `<!-- cjdoc-bind ... -->` | [指南 Markdown 与 API 绑定](#指南-markdown-与-api-绑定) |

注释内容全部来自作者：cjdoc 不会补写摘要、参数说明或译文，也不会把作者写的说明升级为编译器证明。

## 注释识别

- 只有声明前紧邻的 `/** ... */` 绑定到该声明；`//` 与 `/* ... */` 不生成文档。
- 正文按 Markdown 解析。第一段顶层普通段落是摘要，其余顶层普通段落是详细说明；只有标题、列表、引用、代码块等非段落块时，它们全部留在详细说明里，不会提升为摘要。
- 结构化 `@...` 标签必须位于顶层 Markdown 段落。代码围栏、缩进代码、列表或引用里的同样文字只是正文。
- 单段标签的说明可以换行续写，空行结束该段并回到正文。`@group`、`@tag`、`@replacement` 是单行元数据；`@deprecated` 可以包含段落和列表。
- 不认识的 `@...` 保留为普通正文，不要依赖拼错的标签被解释。
- 默认只展示 `public`、`protected` 声明；`internal`、`private` 由 `--audience` 选择，见[状态与限制](states-and-limits.md#可见范围与快照身份)。

## 支持的标签

| 标签 | 内容 | 规则 |
|---|---|---|
| `@param name 说明` | 参数说明 | 名称必须与声明中的真实参数名一致，每个参数一项；不存在报 `CJDOC3109` |
| `@return 说明` | 返回值区域 | 每种语言一项；普通单语重复报 `CJDOC3003`，本地化时同语言冲突报 `CJDOC3106` |
| `@throws Type 说明` | 可能抛出的异常 | 可重复；同一声明重复写同一异常报 `CJDOC3022`；未写说明报 lint `missing-throws` |
| `@see 目标 说明` | 相关声明引用 | 目标无法唯一解析时报 `CJDOC3008` 或 lint 规则 |
| `@since 版本` | 引入版本 | 2–4 段数字，如 `0.1.0`；其他形式报 lint `invalid-since-version` |
| `@deprecated 说明` | 弃用标记与原因 | 无说明仍保留弃用状态，但报 lint `deprecated-without-message` |
| `@replacement 限定名` | 可点击的替代 API | 每个声明最多一条，不加语言限定，见[弃用与迁移](#弃用与迁移) |
| `@author 名称` | 作者 | 可重复 |
| `@version 版本` | 版本元数据 | 不参与多语言配对 |
| `@example [标题] {指令}` | 示例标题、指令与随后的代码围栏 | 见[示例](#示例) |
| 九种行为契约 | 条件、状态与调用边界 | 见[行为契约](#行为契约) |
| `@group id 标题` | 展示分组 | 每个声明最多一个，见[分组与标签](#分组与标签) |
| `@tag id` | 声明级分类标签 | 可重复，见[分组与标签](#分组与标签) |
| `@note 正文` | 注意 | 可重复；默认独立显示，见[提示标签](#提示标签) |
| `@warning 正文` | 警告 | 可重复；默认独立显示，见[提示标签](#提示标签) |
| `@danger 正文` | 危险 | 可重复；默认独立显示，见[提示标签](#提示标签) |
| `@summary 摘要` | 显式摘要 | 配置默认语言后，每种语言一项；覆盖首段自动提取，见[多语言注释](#多语言注释) |
| `@description 说明` | 显式详细说明 | 配置默认语言后，每种语言一项，可含多段或列表，见[多语言注释](#多语言注释) |

行为契约描述作者记录的内容，不是编译器证明、测试回执或兼容性保证。`@since`、`@version`、`@author`、`@group`、`@tag`、`@replacement` 是共享元数据，不能加语言限定。

### 弃用与迁移

在声明上写源码 `@Deprecated` 或文档标签 `@deprecated`，HTML 会在 API 名称或签名旁显示「已弃用」。详情优先显示 `@deprecated` 说明；只有一种语言写了说明时，其他语言可显示带回退标记的原文。没有作者说明时，可读取 `@Deprecated` 的字符串消息并标为「源码说明」。没有可读消息时只显示弃用状态。

要提供独立的「改用」链接，在同一个注释里写一条 `@replacement`，使用替代 API 的限定名。目标有重载时，加上参数类型列表，如 `pocketkit.TextCatalog.add(String)`。把迁移原因和需要区别处理的返回值写在可翻译的 `@deprecated` 里：

```text
@replacement pocketkit.TextCatalog.first
@deprecated 调用 `catalog.first()` 后分别处理三种结果：

- `None`：目录没有条目。
- `Some("")`：首项存在，但内容为空。
- `Some(text)`：首项非空，取出 `text`。

@see pocketkit.TextCatalog.isEmpty
```

把 `@replacement` 放在顶层，和列表、代码围栏等 Markdown 块用空行隔开。它不标记弃用；`@see`、行内代码和源码注解的消息也不生成迁移链接。目标为空、不唯一、指向自己、对当前读者不可见或无法验证时，`CJDOC3138` 指向注释位置，页面仍保留弃用状态与说明。

在 [PocketKit 弃用示例](../../examples/pocketkit/demo-v2/docs/doc-comments.md#弃用与版本)对照两种结果：`firstTextOrEmpty` 显示弃用原因，但没有替代链接；`requireFirstText` 另有「改用 `TextCatalog.first()`」。点击旧名称仍打开旧 API。

### 行为契约

一项契约时显示该项标题；多项时在「行为约束」下分项展示。可以组合不同种类；要配对译文，每种契约在每种语言中只写一项。普通单语注释可写多条；说明为空时报告 `CJDOC3043`。

| 写法 | 显示的约定 | PocketKit 示例 |
|---|---|---|
| `@precondition 0 <= index < size。` | 调用前的必要条件 | `TextCatalog.at` |
| `@postcondition size 比调用前增加一。` | 成功调用后成立的条件 | `TextCatalog.add(String)` |
| `@invariant 会话一旦关闭就不会重新打开。` | 始终成立的约束 | `TextReader` |
| `@performance 最多检查 size 个条目。` | 时间、空间或工作量边界 | `TextCatalog.contains` |
| `@state 读到末尾时 read() 返回 None，会话仍然打开。` | 状态或状态转换 | `TextReader` |
| `@concurrency 多个线程共享读取位置时，调用方必须同步访问。` | 并发使用责任 | `TextReader` |
| `@platform 只读内存文本，不打开文件句柄。` | 平台或环境条件 | `TextReader` |
| `@compatibility 旧的单参数调用仍有效，使用默认的十进制。` | 旧用法与兼容条件 | `TextCatalog.add(Int64, radix:)` |
| `@error radix 不是 10 时，不追加任何条目。` | 失败时的可见行为；具体异常用 `@throws` | `TextCatalog.add(Int64, radix:)` |

在 [PocketKit 行为契约示例](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/docs/doc-comments.md#行为契约)里对照中英文源码与关联 API。契约和 `@throws` 都是说明，不会触发行为检查。

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

## 项目注释字段

项目可以在所属模块的 `cjdoc.toml` 用 `[comments]` 声明正式字段和别名（配置写法见[配置参考](configuration.md#comments项目注释规范)）。声明之后，同样的 `/** ... */` 注释里可以写字段标签：

```cangjie
package sample

/**
 * 读取指定数量。
 * @maintainer platform
 */
public func read(count: Int64): Int64 { count }
```

```toml
[comments.aliases]
maintainer = "owner"

[[comments.fields]]
id = "owner"
title = "负责人"

[comments.fields.titles]
en = "Owner"
```

- `@maintainer platform` 归一为正式字段 `owner`，值是 `platform`；HTML 和 Markdown API 页都显示该字段，中文标题为「负责人」，英文为「Owner」。在 HTML 搜索中按字段值 `platform` 筛选可找到该声明。
- 字段值只取标签所在行、分隔空白之后的文本；去掉首尾 ASCII 空白，保留内部空格、大小写和标点。它不被当作 Markdown、链接或 HTML，也不会自动翻译。
- 字段行不算正文：后续普通段落仍是说明。同一单值字段写两次（即使拼写或值相同）报 `CJDOC3141`，该声明在这个字段上没有有效值；`repeatable = true` 的字段按源码顺序保留每个合法条目。
- 只有作者显式写出的标签才算。隐式 Markdown 摘要、自动回退的译文都不满足规则。
- 顶层段落里完整拼写的标签才算字段；代码围栏、缩进代码、列表和引用里的同样文字是正文。

字段配置错误（`CJDOC3139`）在生成前失败，退出码 `2`。注释结构错误属于错误级诊断，即使 `--lint-profile off` 也退出 `1`：

| 诊断 | 触发条件 |
|---|---|
| `CJDOC3140` | 字段没有值、值超过 16384 个 Unicode 码点、值里有换行或分隔符、含控制字符，或字段行带属性（如 `@owner[lang=en] platform`） |
| `CJDOC3141` | 单值字段在同一注释里出现两次；指向首次与冲突处，该字段整项无效 |

规则（`[[comments.rules]]`）只在 `standard`、`strict` 下执行，严重级别来自规则本身：

```
error[CJDOC3142]: documentation is missing required @owner (required when @deprecated is present)
```

`check` 遇到错误级规则退出 `1`；只有警告时退出 `0`，加 `--deny-warnings` 退出 `1`。

## 提示标签

只识别小写的 `@note`、`@warning`、`@danger`，且必须在顶层 Markdown 段落。标签之后的连续顶层普通文本行构成提示正文；空行、下一条顶层 `@...` 或注释结束会结束提示，其后的普通说明需要用空行隔开。列表、引用、代码块里的同样文字，以及 `@Warning`、`@noteish`，都按普通正文处理。

### 在同一声明里写多个提示

同一声明可以重复使用同一级别，也可以混用 `@note`、`@warning`、`@danger`。HTML 默认按注释顺序逐条显示；读者可在[显示设置](../how-to/generate-and-publish.md#2-阅读页面搜索和深链)中选择按类型合并，不用改注释。成员列表折叠时，警告和危险各最多显示一个标记；展开后才显示全部正文。

例如，给一个按分隔符拼接原始条目的方法写：

```text
@note 连接结果保留条目的插入顺序。
@note 分隔符可以包含多个字符。
@warning 连接时不会转义条目内容，不能代替 CSV 编码器。
@danger 不要用连接结果覆盖原始条目；不同条目可能产生相同结果。
```

### 在一个提示框内分条

同一事项需要分点时，用一条标签写列表，而不是重复标签。列表里的所有条目同属该标签的级别。把编号都写在同一行只会得到一段文字。

要在一个提示框内显示有序列表，把 `1.` 写在标签同一行，再在后续行写 `2.`、`3.`，中间不留空行。渲染时每一项单独成行：

```text
@warning 1. 校验分页起点，避免越界。
2. 按实际返回的条目数遍历，不要假定末页已填满。
```

要在一个提示框内显示无序列表，第一项用 `@note + 正文`；其余各项先单写一行 `+`，再在下一行缩进两个空格写正文。各项之间不留空行。直接写 `- 正文` 会让后续项成为提示框外的正文列表。

```text
@note + 在起点有效时，`limit: 0` 返回空窗口。
+
  读取窗口不会移除或重排目录里的条目。
```

PocketKit 的 [`TextCatalog.window` 源码](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/src/catalog.cj) 在同一声明中分别演示这两种列表；`TextCatalog.join` 演示重复和混用提示。

### 属性与诊断

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

同一声明可写多个 `@example`。每个标签对应站点「示例」区的一条独立用例，标题可省略。一个标签下的多个 `cangjie` 围栏按顺序拼接成**同一个用例**，可跨围栏使用先前定义的变量；另一个 `@example` 不共享这些变量。示例延续到下一个受支持的顶层标签，围栏内形似标签的文字不结束示例。

下面的 `add` 有两个用例。第一个用例的两个代码块一起执行，标准输出为 `3`；第二个用例独立编译，只检查代码能否通过。HTML 和 Markdown 默认只展示；要执行指令，显式加 `--check-examples`。

~~~cangjie
/**
 * 返回两个数值的和。
 * @param left 左操作数。
 * @param right 右操作数。
 * @return 两数之和。
 * @example 将结果保存后打印 {run}
 * ```cangjie
 * let sum = add(1, 2)
 * ```
 * ```cangjie
 * println(sum)
 * ```
 * ```output
 * 3
 * ```
 * @example 传入负数 {must-pass}
 * ```cangjie
 * let sum = add(-2, 1)
 * println(sum)
 * ```
 */
public func add(left: Int64, right: Int64): Int64 {
    left + right
}
~~~

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

只有非空的小写 `cangjie` 围栏参与检查；反引号和波浪线均可，`cj` 只高亮。检查时没有可编译围栏报 `CJDOC3032`；有指令时也报 `CJDOC3070`。

每个有代码的示例最多一个 `output` 围栏，且必须与 `run` 同用。省略 `output` 只检查正常退出；空 `output` 要求没有标准输出。比较时统一换行符并忽略首尾空行。示例包在无参数 `main` 里执行，不能使用 `args`。

生成页面会展示作者写的预期输出，不会自动采集运行结果。可在 PocketKit 的 [`TextCatalog.window` 源码](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/src/catalog.cj) 看到四个带输出的用例：正常分页、默认值与末页、空窗口、非法参数。生成 PocketKit 文档后，在 `window` 页的「示例」区可看到每个用例的代码和预期输出。

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

### HTML 示例布局

小写 `cangjie` 围栏和随后的 `output` 默认合为一个示例单元，先代码后输出。两区可独立复制；复制输出保留围栏内捕获的空格、制表符和换行。超过 12 行的输出默认折叠，可展开查看，折叠时也可复制全文。空 `output` 显示「预期无标准输出」，没有 `output` 则不显示输出区。

点示例标题可开合整例。读者可在「显示设置」里分别选择整例与长输出的默认状态；单独开合不影响默认设置。

在 `output` 围栏首行选择布局：

| 围栏首行 | 页面效果 |
|---|---|
| ` ```output ` | 一体式上下布局（默认） |
| ` ```output layout=prose ` | 紧贴在代码块下方的正文式输出，适合教程 |
| ` ```output layout=side-by-side ` | 桌面阅读区足够宽时左右并排；触屏与窄屏仍先代码后输出 |

布局只影响 HTML，不改变编译、运行或输出核对。首页与指南 Markdown 也可用这三种写法：把顶层的 `output` 围栏紧跟在一个或多个小写 `cangjie` 围栏后。两者之间可以写「预期输出」作普通或加粗段落，不要插入标题或其他正文。参见 [PocketKit 示例与输出](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/docs/doc-comments.md#示例与输出)。

## 多语言注释

cjdoc 不自动翻译，也不校验译文是否正确、同步或最新；每种语言的正文由作者提供。启用多语言需在项目自己的 `cjdoc.toml` 里配置 `[i18n]`，见[配置参考](configuration.md)。目前只发布 `zh-CN` 与 `en`，语言标签按大小写归一化到这两个值，不推断 `zh-Hans`、`zh-TW`、`en-US` 等别名。

可本地化字段：摘要、详细说明、参数、返回值、异常、引用、弃用、示例、九种行为契约，以及 `@note`、`@warning`、`@danger`。

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

不写 `@summary` 时，从顶层首个普通段落取摘要。要分别指定摘要和多段详细说明，可照抄 [PocketKit 的弃用示例](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/docs/doc-comments.md#弃用与版本)。

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

不同提示若要分别翻译，各用不同的 `id`；同一条提示的中英文共用 `id` 和提示级别。三个提示等级在同一声明内共用 ID 命名空间。有 ID 且有效的提示先取请求语言，再取所属输入的默认语言；仍缺时只在存在唯一有效其他语言候选时回退，并标注正文的实际来源。没有有效正文的 ID 变体不能因回退而被算作完成译文。

```text
@warning[id=csv] 连接不会转义，请使用专用 CSV 编码器。
@warning[lang=en,id=csv] Joining does not escape entries. Use a CSV encoder.
@warning[id=empty-result] 请用 `isEmpty()` 判断目录是否为空。
@warning[lang=en,id=empty-result] Use `isEmpty()` to test whether the catalogue is empty.
```

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
