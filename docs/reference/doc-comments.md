# 文档注释参考

本页说明仓颉声明注释的完整标签、示例、分组/分类与注释内多语言规则。初次生成教程使用较小的 `greet` 示例；下面另有一个独立且完整的 `clamp` 函数，用来说明真实的异常行为，不是 `greet` 的替代实现。项目首页、包概述和指南中的 Markdown 语法见[添加指南](../tutorials/add-guides.md)，配置项见[配置参考](configuration.md)。

## 注释识别与正文划分

- 只有声明前紧邻的 `/** ... */` 文档注释绑定到该声明；普通 `//`、`/* ... */` 注释不生成文档。
- 仓颉源代码中的注释需按 Markdown 结构解析。第一段顶层普通段落是摘要（summary）；其余顶层普通段落构成详细说明（description）。若注释只有标题、列表、引用、代码块等非段落块，它们全部保留为详细说明，不会把标题或代码块提升为摘要。
- 正文支持 Markdown。结构化 `@...` 标签必须在顶层 Markdown 段落中；代码围栏、缩进代码、列表或引用中的相似文字只是内容，不是标签。
- 普通单段标签的说明可换行续写，空行结束该段并返回正文；`@group`、`@tag` 是单行元数据。示例和带语言限定字段有各自的连续内容规则，见下文专节。下一条受支持的顶层标签开始相应字段；未知标签保留为普通正文，不应依赖拼错的标签被解释为有效契约。
- 默认 API 站点只展示 `public`、`protected` 声明；`internal`、`private` 可通过 `--audience` 选择。输出范围详见[状态与限制](states-and-limits.md#可见范围与快照身份)。

### 宏声明与宏包裹的源码

`public macro` 使用函数式的参数、返回及示例标签；cjdoc 收集源码签名，并在 HTML 的“宏”分组展示。对 `@Derive[Equatable]` 等宏包裹的声明，收集的是输入中的源码声明和成员：声明前的注释绑定整个宏包裹声明，成员保留自己的源码位置，嵌套宏同样适用。

cjdoc 不执行宏。宏调用保留在 `macroInvocations`，通过 `CJDOC1009` 说明生成成员未知，文档保持 `partial`；不能恢复为源码声明的输入进入 `unsupportedDeclarations`。宏生成的方法和接口实现不因此进入 API 清单，源码已有声明仍可搜索、链接和离线查询。

## 支持的标签

| 标签 | 内容与注意事项 |
|---|---|
| `@param name 说明` | 参数说明；参数名必须和声明中的真实参数名对应。每个参数一项。 |
| `@return 说明` | 返回值说明；每个注释只支持一个 `@return`。`Unit` 无返回值覆盖率分母，但作者正文仍保留。 |
| `@throws ExceptionType 说明` | 可能抛出的异常；可重复，每种异常写出真实类型与触发条件。显式配对 ID 见[多语言注释](#多语言注释)。 |
| `@see 目标 说明` | 相关声明引用，会进行目标解析与质量检查。 |
| `@since 版本` | 引入版本；质量规则接受 2–4 段数字，例如 `0.1.0`。 |
| `@deprecated 说明` | 弃用标记与原因；无说明仍保留弃用状态，但质量规则会报告。 |
| `@author 名称` | 作者元数据；可重复。 |
| `@version 版本` | 版本元数据；不用于多语言配对。 |
| `@example [标题]` | 示例标题和随后的代码块；示例校验须显式启用，见下文。 |
| `@precondition` | 调用前条件。 |
| `@postcondition` | 调用后保证。 |
| `@invariant` | 不变量。 |
| `@performance` | 性能或复杂度特征。 |
| `@state` | 状态读取或副作用。 |
| `@concurrency` | 并发、同步要求。 |
| `@platform` | 平台或运行环境限制。 |
| `@compatibility` | 兼容性说明。 |
| `@error` | 错误处理和失败行为。 |
| `@group id 标题` | 声明的一个展示分组；集中配置可提供标题，见[分组与标签](#分组与标签)。 |
| `@tag id` | 声明级分类标签，可重复，见[分组与标签](#分组与标签)。 |
| `@note`、`@warning`、`@danger` | 作者标记的提示块，语义由作者选择，不由 cjdoc 推断风险。 |

行为契约按标签类别分组显示；契约描述的是作者记录，不是编译器证明、测试回执或兼容性保证。`@since`、`@version`、`@author`、`@group`、`@tag` 是共享元数据，不参与普通语言译文选择。对于 API 实际行为，作者应先核对实现，见[复核作者契约](../how-to/review-contracts.md)。

### 完整的 `clamp` throws 示例

把下面的完整源码文件单独保存为 `src/clamp.cj`；`package docdemo` 与首次教程的包名相同。它是独立的公开声明文件，不含 `main`，可与 `greet` 文件一起编译。代码编译不依赖 cjdoc 配置；若要用 cjdoc 发布双语注释，所属项目的 `[i18n]` 必须设置 `default-language = "zh-CN"` 和 `languages = ["zh-CN", "en"]`。本例专门讲实际 throws 行为，不替换 `greet`；两种语言的异常条目以 `invalid-bounds` 显式配对。

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

该实现把区间外的 `value` 截到最近边界；`lower == upper` 时返回该边界，`lower > upper` 时抛出 `IllegalArgumentException`。如何亲自编译和运行此文件，见[检查文档示例](../how-to/check-examples.md)。

## 分组与标签

### `@group`：展示组织

每个声明最多一个 group。ID 是 1–64 个 ASCII 字母、数字、连字符或下划线；大小写敏感。内联标题必须为 1–256 UTF-8 字节的单行非空白纯文本，不得含 C0/DEL 控制字符。

```cangjie
/**
 * 将文本写入输出。
 * @group 20-serialization 序列化
 */
public func writeText(): Unit {}
```

`@group <id>` 可以省略标题，但必须能与同一个 module、package、owner scope 的 `[metadata.groups]` 定义匹配，否则报告 `CJDOC3137`，该分组不生效。集中配置也可用 `owner` 全限定名或 `owner-id` 精确约束声明容器；二者不能同时设置，支持 class、struct、interface、enum、extend。配置表、标题译名、顺序与 scope 诊断见[配置参考](configuration.md)。

不同 module/package/原始 owner 中的同名 ID 是不同分组。声明种类层级按当前可见声明决定；显式 order 先排序，未排序组位于其后，未分组声明最后。标题只影响显示，不改变 API 身份、可见性、兼容性分类或 SymbolId。组与 kind 的历史深链锚点会保留；多个 scope 共用一个页面时，旧式短锚点只绑定到确定的 primary scope，其他 scope 使用独立锚点。

非法或重复 inline group 报 `CJDOC3130`；同 scope 中相同 ID 的内联标题冲突报 `CJDOC3131`。`@group[lang=...]` 不允许，报 `CJDOC3112`。

### `@tag`：分类集合

每个 `@tag` 行只包含一个 ID。ID 为 1–64 个 ASCII 字母、数字、`-`、`_`，大小写敏感；多个不同 tag 可附在同一声明：

```cangjie
/**
 * 以流式方式发送数据。
 * @group 20-serialization 序列化
 * @tag streaming
 * @tag extension-point
 */
public func sendStream(): Unit {}
```

重复 ID 在同一声明中按集合去重；输出次序按 ID 的 UTF-8 字节排序。非法字符、空 ID、超长 ID 或多余参数报告 `CJDOC3132`；非法项不会进入 tag 集合，但不会删除声明。`@tag` 不能接续正文，也不能使用语言限定。

Tag 只属于写有该注释的声明，不从包、类型、基类、扩展或重载族继承。tag 不是行为契约，不进入契约质量分或翻译覆盖率分母，也不改变源码/API 身份。配置中的标题仅用于显示；查询、HTML 搜索和 facets 都按大小写敏感的完整 ID 匹配，多个 tag 条件取 AND 交集。配置标题见[配置参考](configuration.md)。

## 提示标签

注释仅识别小写 `@note`、`@warning`、`@danger`，必须位于顶层 Markdown 段落。标签后的连续顶层普通文本行构成提示正文；空行、下一条顶层 `@...` 行或注释结束会结束提示。其后的普通说明需要空行与提示隔开。列表、引用、代码块、引用内的相似文字、`@Warning`、`@noteish` 都按普通正文处理。

提示属性只能按以下形式和顺序书写；不加空格或引号：

```text
@warning
@warning[id=stale-cache]
@warning[lang=en]
@warning[lang=en,id=stale-cache]
```

作者 ID 为 1–64 ASCII 字节，首字符必须是小写 `a-z`，余下字符只能是小写字母、数字、`_`、`-`。相同 ID 在同一语言重复，或在不同提示等级间复用，报 `CJDOC3118`；不能把 warning 自动改成 danger。没有 ID 的条目不按位置、正文或唯一候选配对。空提示或只有 Markdown 引用定义、没有可见正文时报告 `CJDOC3117`，保留原文但不渲染空提示块。属性结构错误为 `CJDOC3115`，ID 错误为 `CJDOC3116`；语言结构/不支持分别为 `CJDOC3102`、`CJDOC3103`。

提示等级是作者意图。HTML 使用静态且可见等级标题的提示区域；正文走安全 Markdown renderer，不当作 HTML 注入，不产生弹窗、`role="alert"` 或 live region。API 提示只通过注释标签创建；指南 Markdown 引用块的提示标记规则属于概念页输入，见[添加指南](../tutorials/add-guides.md)。

## 示例

`@example` 标题可省略。示例正文中一个或多个 `cangjie` 代码围栏依序合成一个示例；直到下一个受支持的顶层标签结束。围栏里的标签样式文字仍属于示例内容。生成 HTML/Markdown 会显示示例，但默认不编译或运行；检查须显式加 `--check-examples`。

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

支持的指令：

| 指令 | 作用 |
|---|---|
| `must-pass` | 要求示例实际编译通过。 |
| `must-fail` | 要求编译失败且错误归因于示例文件本身。 |
| `error="文本"` | 与 `must-fail` 一起使用，要求诊断包含文本。 |
| `run` | 编译通过后作为程序运行，要求退出码为 0。 |
| `flags="..."` | 限定的 `cjc` 编译选项，见下列白名单。 |

指令名区分大小写且不可重复；`must-pass` 与 `must-fail` 互斥，`run` 不能与 `must-fail` 同用，`error=` 必须搭配 `must-fail`。语法冲突、未知指令或非白名单参数报告 `CJDOC3033`，该示例不编译。`flags` 白名单仅有：`--cfg NAME=VALUE`（用户配置键）、`-Woff GROUP` / `-Won GROUP`（`all`、`unused`、`unused-main`、`deprecated`、`unsupport-compile-source`、`package-import`、`parser`、`semantics`、`interpreter`、`apilevel-check`）、`--int-overflow throwing|wrapping|saturating`，以及单独的 `--experimental`、`-O0`、`-O1`、`-O2`、`-Os`、`-Oz`。输入/输出路径、依赖、import、包配置等不由示例指令控制。

每个示例最多一个 `output` 围栏，且必须与 `run` 一起使用。比较时统一换行符并忽略首尾空行。示例包在无参数 `main` 中执行，不能使用 `args`；需要的 import 必须位于所属源码文件中，代码片段只写函数体内语句。运行依赖可用静态链接和地址空间限制，环境无法满足时拒绝运行（例如 `CJDOC3074`）。

固定边界：单次运行 10 秒（`CJDOC3073`）；stdout/stderr 各最多 64 KiB（`CJDOC3075`）；内存最多 2048 MiB，不能建立限制时拒绝运行（`CJDOC3074`）；单次检查最多 256 个示例。其他结果码：示例自身编译失败 `CJDOC3030`；失败不能归因于示例（如所属源码上下文无法编译）`CJDOC3031`；未真正检查/受限跳过 `CJDOC3070`；运行退出码非零 `CJDOC3071`；实际 stdout 与 `output` 不一致 `CJDOC3072`。逐例结果通过诊断和退出码报告，不生成独立结果文件或执行徽章。命令和失败分类见[检查文档示例](../how-to/check-examples.md)。

## 多语言注释

`cjdoc` 不自动翻译，也不验证译文是否正确、同步或最新。每个受支持语言的正文由作者提供。启用多语言需在输入自己的 `cjdoc.toml` 中配置 `[i18n]`，完整发布配置见[配置参考](configuration.md)。目前只发布 `zh-CN` 与 `en`，语言标签按大小写归一化到这两个值，不推断 `zh-Hans`、`zh-TW`、`en-US` 等别名。

可本地化字段为摘要、详细说明、参数、返回值、异常、引用、弃用、示例和九种行为契约。字段形式如下：

完整的双语注释和实际 throws 配对见本页上方的完整 `clamp` 示例。以下只展示语言字段的标签形状，不是另一段源码或可编译声明：

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

语言限定必须紧跟标签名并在同一行，如 `@param[lang=en] text ...`。`@param` 译文仍需提供真实参数名；语言限定之后的多段说明、列表、表格、引用和围栏都属于该译文。自然语言限定不会重解释代码围栏语言或 `{run}` 等示例指令。

`@since`、`@version`、`@author`、`@group`、`@tag` 是共享元数据，禁止加 `[lang=...]`，报 `CJDOC3112`。普通本地化字段要求所属输入能确定 `default-language`；无配置时触发完整本地化范围会报 `CJDOC3105`。工作区成员无自有配置时可继承 workspace 根选项；path/cache 依赖各读自己的语言元数据，不继承根项目默认语言。

### `@throws` 条目身份

普通 `@throws Exception 说明` 在异常类型能唯一绑定时可配对；不能证明唯一目标时，可用显式 ID。下例重复展示上方真实 `clamp` 文件中的同一个边界异常配对：

```cangjie
/**
 * @throws[id=invalid-bounds] IllegalArgumentException 当 lower 大于 upper 时抛出。
 * @throws[lang=en,id=invalid-bounds] IllegalArgumentException Thrown when lower is greater than upper.
 */
```

ID 只在当前声明的 `@throws` 条目中生效，1–64 字节，首字符小写 `a-z`，其余只能小写字母、数字、`_`、`-`。只接受 `[id=...]` 或 `[lang=...,id=...]`，顺序固定。其他属性顺序或多余属性会被拒绝；错误 ID 报 `CJDOC3113`。同语言复用 ID，或跨语言同 ID 指向不同异常主体/唯一解析目标，报 `CJDOC3114`；保留原文、不强行配对。显式 ID 证明的是两条作者说明的关联，不是异常类型链接已解析；本例源码模式仍可能为标准库异常报告 `CJDOC3109`，同时保留正确的双语条目身份。

### 提示的语言配对与回退

提示只支持 `@note`、`@warning`、`@danger`。属性允许空、`[id=x]`、`[lang=en]`、`[lang=en,id=x]`；language 在 ID 前。提示 ID 与 throws ID 采用同样字符形状，但作用域不同：提示三个等级在同一声明共用 ID 命名空间。同一语言重复、跨等级复用 ID 报 `CJDOC3118`；冲突内容分别保留为 `unpaired`，不选其一、不改等级。无 ID 提示永不按顺序或正文配对，多语言变体可同时显示并在适用时报告 `CJDOC3107`。

有 ID 且有效的提示优先选择请求语言，再选择所属输入的默认语言；仍缺时仅在唯一有效其他语言候选存在时回退，并标注正文实际来源。没有有效正文的 ID 变体不能因回退而被算成完成译文。

没有 `[i18n]` 时，普通注释字段仍按未本地化内容显示；但如果注释有顶层提示标签且没有触发完整本地化的普通字段，它可处于 `localizationScope = "admonitions"`，只允许提示使用 `[lang=...]` 与 ID，普通正文和其他标签保持原样。启用 `[i18n]` 或同一注释使用普通语言字段、`@summary`、`@description`、带 ID 的 throws 等完整本地化触发项时，范围为 `all`，未限定的正文属于配置的默认语言。

### 译文选择、诊断与页面边界

通常按请求语言、输入默认语言、缺失顺序选择正文。显式 `@throws` ID 或提示 ID 在两者都无效时可从唯一有效其他语言回退。回退不会被视为完整译文。summary/description/param/return/deprecated 等同一语言同一字段重复时两处都标为 conflict，不以后一条覆盖；引用和 throws 的重复项只有可证明的目标/ID 及每语言唯一时才配对。契约按契约种类且每语言唯一时配对；示例不按标题、行号或数组位置配对。不能证明时保留为独立项并可能报告 `CJDOC3107`。

主要诊断：`CJDOC3101` 普通语言头语法错误；`3102` 语言标签结构错误；`3103` 不支持语言；`3104` 文本语言未列入当前输入发布集合；`3105` 缺默认语言；`3106` 单语言同字段重复；`3107` 不能唯一配对；`3108` 缺译、回退、空译、冲突、未知来源或未配对（按 `missing-translation` 可升级）；`3109` 参数不存在或引用/throws 目标无法唯一绑定；`3110` 页面 ID/语言或章节映射问题；`3111` 翻译覆盖率低于门槛；`3112` 共享元数据加语言限定；`3113` throws ID 非法；`3114` throws ID 冲突；`3115` 提示属性语法错误；`3116` 提示 ID 非法；`3117` 空提示；`3118` 提示 ID 同语言重复或跨等级冲突。退出码和报告状态见[状态与限制](states-and-limits.md#多语言与诊断状态)。

项目首页只有一个 `index` 文件，不按语言 ID 配对；其他语言阅读时仍显示同一内容，并可能标记内容语言未知或原文。指南页面则由配置中同 `id`、不同 `language` 配对，章节通过同一逻辑键映射到各自标题的实际锚点；详情见[发布多语言页面](../tutorials/publish-languages.md)。

## 指南 Markdown 与 API 绑定

本节是语法参考；代码围栏是局部 Markdown 片段，不是独立仓颉程序。完整页面与配置见[添加指南教程](../tutorials/add-guides.md)。

页面支持标题、段落、列表、表格、引用、代码块、行内代码、强调、链接和本地栅格图片。原始 HTML 按文本处理，不直接注入页面；独占一行的 `cjdoc-bind` 标记具有下述特殊含义。指向其他已登记概念页源文件的相对链接会映射成输出路由，同页标题 fragment 会映射成实际锚点；指向未登记文件的普通相对链接保持原样，发布前由作者检查目标是否随站点提供。

PNG、JPEG、GIF、WebP、AVIF 可在安全捕获后随站点发布；远程图片 URL 不会自动下载并嵌入。SVG 不属于本地图片输入格式。平台与资源边界见[状态与限制](states-and-limits.md#能力边界)。

### Markdown 提示块

只有 `[!NOTE]`、`[!WARNING]`、`[!CAUTION]` 会分别成为 note、warning、danger。Marker 必须独占顶层引用块首段的第一条物理行，后面有可见正文：

```markdown
> [!NOTE]
> 名字中的空白会被原样保留。

> [!WARNING]
> 发布前核对输入版本，避免混用旧快照。

> [!CAUTION]
> 删除站点前先确认备份和输出所有权。
```

`> [!WARNING] 正文` 不满足独占 marker 规则；`[!DANGER]`、`[!TIP]`、`[!IMPORTANT]`、拼写错误，以及列表/嵌套引用中的 marker 都保留为普通引用。只有 marker 或仅有引用定义而没有正文节点时，保留普通引用并报告 `CJDOC3117`；诊断指向指南文件，不虚构 API 身份。页面其余内容仍可生成。

HTML 使用静态提示区域和可见本地化等级标题，正文继续经过安全 Markdown renderer，不产生 alert、live region 或弹窗。Markdown 输出保留引用形式，danger 对应 `[!CAUTION]`。注释中的 `@note` 等标签与这里的引用语法是两种不同输入。

### 精确关联 API 与重载

标记独占一行，不能放在代码块或缩进代码中：

```markdown
<!-- cjdoc-bind target="docdemo.greet" -->
```

| 属性 | 匹配规则 |
|---|---|
| `target="docdemo.greet"` | 限定名完全相等，不按短名猜目标。 |
| `target="id:<稳定 ID>"` | SymbolId 完全相等；从生成的 navigation index 复制实际 ID。 |
| `selector="signature:public func greet(name: String): String"` | 与 target 一起精确选择源码声明头，尤其用于重载。 |
| `language="cangjie"` | 可选的记录属性，默认 markdown；不是译文配对开关。 |

一个页面可写多个标记。找到唯一且受众可见的声明时，原位置显示“相关 API”和签名；API 反向入口指向标记所在的可证明章节，没有章节证据时回到文章。页面底部可展开全部 API 关联；Markdown 输出在末尾列出关联。

找不到目标为 `CJDOC2051`，歧义为 `2052`，重复目标为 `2053`，当前受众不可见为 `2055`。这些情况保留页面并显示相应未绑定状态，不静默选一个 API；重复标记不是两份有效关联。

模块页默认读取 `docs/modules/<slug>.md` 并发布为 `concepts/modules/<slug>.html`，无正文文件时提供中立占位说明。配置的指南和包概述规则、自动页面、路由冲突及章节映射以[配置参考](configuration.md)为准；导航实际路由以输出索引为准，不能从标题猜哈希。