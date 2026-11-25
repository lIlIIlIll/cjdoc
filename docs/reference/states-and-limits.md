# 状态与限制参考

文档、快照和查询结果里出现的状态词、可见范围的含义，以及当前实现的固定资源上限。状态词属于不同字段，同一个英文词在不同对象上含义不同，不要互相替代。命令与退出码见 [CLI 参考](cli.md)，配置级限制见[配置参考](configuration.md)，注释与示例限制见[文档注释参考](doc-comments.md)，查询域的完整状态与预算见[查询协议](query-protocol.md)。

## 快速索引

| 你看到 | 它在哪个字段 | 去看 |
|---|---|---|
| `status` 为 `complete`／`partial` | 生成快照整体完整性 | [结果完整性状态](#结果完整性状态) |
| `apiCollectionState` | API 收集范围 | [结果完整性状态](#结果完整性状态) |
| `ok`／`ambiguous`／`not_found`／`source_incomplete` | 查询域状态 | [查询完整性与状态](#查询完整性与状态) |
| `resolved`／`unresolved`／`unavailable` | 解析与链接状态 | [解析、匹配与语义状态](#解析匹配与语义状态) |
| `matchLevel` 为 `exact`／`compatible`／`manual`／`none` | 依赖文档导航 | [解析、匹配与语义状态](#解析匹配与语义状态) |
| `provenance` 为 `verified`／`declared`／`unavailable`／`ambiguous` | 源码来源 | [源码来源 provenance](#源码来源-provenance) |
| `translationState` | 字段级翻译状态 | [多语言与诊断状态](#多语言与诊断状态) |
| 某条声明没出现在页面上 | 受众与可见范围 | [可见范围与快照身份](#可见范围与快照身份) |
| 报资源错误或输出被截断 | 固定资源上限 | [主要资源上限](#主要资源上限) |
| 覆盖率百分比与实际感觉不符 | 报告口径 | [覆盖率与质量统计](#覆盖率与质量统计) |

## 结果完整性状态

生成快照至少有两个独立字段：

| 字段 | 取值 | 含义 |
|---|---|---|
| `status` | `complete`、`partial` | 整体文档输入、语义处理和发布是否含不完整项。诊断 error、语义能力不可用或歧义、孤立注释、宏调用、未支持声明、未绑定语义声明都会使其为 `partial` |
| `apiCollectionState` | `resolved`、`partial`、`unavailable` | API 收集范围是否完整，独立于页面、lint、高亮等发布诊断 |

两者可以不一致：API 完整收集（`apiCollectionState = resolved`）时，可选高亮后端失败仍会让 `status` 为 `partial`；反过来，有一份 HTML 输出不能证明 API 收集完整。遇到 `partial` 要同时看生成诊断与 `apiCollectionState`，再决定这份快照能否用于覆盖率、严格基线、外部链接或查询范围。

## 查询完整性与状态

查询 envelope 把三件事分开：

| 字段 | 内容 |
|---|---|
| `completeness.apiCollection` | 每个快照的 API 收集状态，不受当前页 `limit` 影响 |
| `completeness.query` | `scope`、`offset`、`returned`、`total`、`complete`、`next`、`coverage` |
| `completeness.content` | `selectedSections`、`omittedSections`、`missingSections`、`retry` |

`total = null` 表示未知，不等于 0。未执行查询时 `coverage` 为 null，不能据此推断「已完整搜索」。关系续取的 `scope` 是 `relations`，`returned` 计关系条数而不是重复的主体声明。

域状态分三组：

| `status` | 类别 | 含义 |
|---|---|---|
| `ok` | 正常结果 | 请求的查询成功 |
| `ambiguous` | 正常结果 | 候选无法唯一决定，需按身份缩小范围 |
| `not_found` | 正常结果 | 在已加载且可见的完整范围内没有匹配 |
| `source_incomplete` | 正常结果 | 输入 API collection 本身不完整，不能据此推断全库不存在 |
| `invalid_request` | 请求错误 | JSON、schema、字段适用性或字段值错误 |
| `scope_mismatch` | 请求错误 | 指定快照、language/audience/cfg 或身份不在加载集合中 |
| `stale_cursor` | 请求错误 | cursor 格式错误、绑定不匹配或偏移越界 |
| `budget_exceeded` | 资源 | 必要内容超过用户 `maxBytes`，可按 `requiredBytes` 重试 |
| `resource_limit` | 资源 | 硬资源或输出上限不允许完成请求 |
| `unavailable` | 资源 | 所需证据、输入或可选能力不可用 |

`not_found` 与 `scope_mismatch` 的区别：前者是范围已正确选中但候选不存在，后者是请求的范围根本不在已加载 catalog 中。退出码映射见 [CLI 参考](cli.md#退出码)。

## 解析、匹配与语义状态

| 状态 | 含义 |
|---|---|
| `resolved` | 找到唯一可用目标；仍要读匹配级别、来源与原因，对依赖目标不等于行为证明 |
| `unresolved` | 在声明的输入与选择范围内没有唯一可用目标；不是「目标在整个生态中不存在」 |
| `ambiguous` | 有多个同优先级或冲突候选，不能任取一个 |
| `unavailable` | 目标可能存在，但当前证据、可见范围、输入、预算或依赖上下文不足以安全解析 |
| `partial` | 部分语义信息可用但不算完整解析；只在语义对象/类型状态上出现，不是 `TypeNavigation.state` 的值 |

`TypeNavigation.state` 只有 `resolved`、`unresolved`、`ambiguous`、`unavailable`。

依赖文档导航的 `matchLevel` 是另一组值：

| `matchLevel` | 含义 |
|---|---|
| `exact` | 被消费的依赖身份、已 pin 的外部库存、发布文档集身份与可匹配的来源/依赖上下文等输入证据互相符合；不认证网站托管者，不证明发布者 API/ABI 真实 |
| `compatible` | 存在显式的 API/构建上下文兼容映射；映射与托管地址是声明，不是远端认证 |
| `manual` | 作者指定但证据不足以自动建立身份关系；旧式 `/1` 索引 URL 也以 `resolved/manual` 输出 |
| `none` | 没有匹配级别，通常与非 `resolved` 状态同时出现 |

本地且处于所选模块依赖上下文中的目标可以是 `resolved/exact`。目标被 audience 排除、同名依赖候选冲突、源码 `import` 无法排除隐式 `std.core` 歧义或导航预算耗尽时，结果为 `unavailable` 或 `ambiguous`，不猜。判断一个结果要同时看 `state`、`matchLevel`、`reason`、目标身份与 URL；只有 URL 字符串不算身份证据。

API 契约快照里，类型/default/返回值等契约字段取 `resolved`、`partial`、`unavailable`、`ambiguous`；基线与当前声明的匹配状态取 `exact`、`fallback`、`ambiguous`、`added`、`removed`；比较结论另为 `breaking`、`potentially-breaking`、`additive`、`documentation-only`、`metadata-only`、`unchanged`。收集不完整或字段不可解析时，diff 不会把它包装成「无变化」。

## 源码来源 `provenance`

Doc IR 的每个源文件记录来源状态：

| 状态 | 能证明什么 | 不能证明什么 |
|---|---|---|
| `verified` | 已登记仓库与调用方独立 pin 的 receipt 和捕获源码字节一致；带来源仓库、仓内相对路径、摘要与 `caller_pinned_receipt` 证据 | Git commit/tree、远端仓库、构建成功、工作树干净，或调用者为何信任该 pin |
| `declared` | 由旧式 `--repository-url`/`--repository-revision` 映射出的仓库与路径声明 | 没有文件摘要与 receipt pin，不是已验证来源 |
| `unavailable` | 当前没有可用来源证明，`reason` 说明缺失或失败原因 | 不应据此构造 GitHub 源码 URL |
| `ambiguous` | 仓库登记互相冲突 | 不能任选一个仓库或路径 |

只有有效源码范围内的 `verified`，或旧映射的 `declared`，才可能投影为源码 URL；后者仍只是声明链接。离线重放保留快照内的状态与证据字段，不重新打开源码、Git 或 receipt，也不重新验证 pin。重导出符号的**暴露位置**与目标声明的**定义来源**是两个字段。

外部文档快照的状态是 `available`、`unavailable`、`ambiguous`；后两者没有可用 URL。`available` 只说明当前本地索引能提供一个链接目标，不证明它对应项目实际解析到的依赖版本。标准库文档 URL 也只是阅读参考。条件与操作见[链接外部文档](../how-to/link-documentation.md)。

## 多语言与诊断状态

`translationState` 的可能值：

| 值 | 含义 |
|---|---|
| `complete` | 请求语言的有效字段可用 |
| `fallback` | 显示其他语言的有效文本，通常是输入默认语言或唯一可证明的配对；注明实际来源语言，不算请求语言的完整译文 |
| `empty-fallback` | 请求语言字段存在但为空，回退显示有效原文 |
| `conflict-fallback` | 请求语言定义冲突，保留冲突事实并回退到有效原文，不以后一条覆盖 |
| `empty` | 字段为空 |
| `conflict` | 同语言重复定义冲突 |
| `missing` | 缺少请求语言字段；不删除 throws、弃用状态等 API 事实 |
| `unknown` | 输入缺少可确认的正文语言信息 |
| `unpaired` | 无法唯一证明跨语言条目关系，按独立条目保留 |
| 空串 | 未设置 |

判断时要结合 `contentLanguage`、请求的 `readingLanguage` 和字段本身。发布语言目前限 `zh-CN` 与 `en`，不自动翻译；`--locale` 只选择界面与已有译文。配对算法与诊断码见[文档注释参考的多语言规则](doc-comments.md#多语言注释)。

指南绑定的 `DocumentationPageBinding.state` 取 `resolved`、`unresolved`、`ambiguous`、`unavailable`、`conflict`；只有 `resolved` 带已绑定的目标 SymbolId。绑定状态与页面导航状态分开记录。页面 ID 与语言决定配对，标题相同不构成身份。

## 可见范围与快照身份

`--audience` 控制面向读者的声明投影：

| 值 | 包含 |
|---|---|
| `external` | `public`、`protected` |
| `package` | 除 `private` 以外的声明 |
| `all` | 全部声明 |

嵌套声明还要满足其 owner 的可见范围。这是文档视图与契约比较范围，不是访问控制、源码过滤或保密边界；`docs.json` 保留捕获模型与配置里的 audience，不要把含内部或私有源码事实的 JSON 交给不受信任的读者。

读取语言、audience、项目/模块身份、目标与 cfg 会影响阅读视图、依赖导航、快照匹配与查询 cursor。`documentationRevision` 是文档发布标签，来自 `--doc-version`，不改变 API 源码或依赖版本；比较两个版本前要分别从对应源码生成快照。

## 能力边界

- 源码生成、检查与离线渲染都不下载依赖、不下载标准库文档、不访问外部文档站；依赖与索引须预先准备。`query`、`mcp` 只消费已捕获快照，不扫描源码、不选择 SDK、不编译、不联网。
- `generate`、`check`、`serve` 默认尝试 CHIR 语义补充，会调用匹配的本机编译器与配套 worker；它仍不是权威的完整类型检查。worker 缺失、版本或协议不匹配、分析失败时保留源码/AST 信息并给出诊断。
- `--semantic source` 或项目 `[semantic].mode = "source"` 只收集源码可见信息，不为语义补充编译项目，也不展开宏。其他条件配置用 `--cfg NAME=VALUE` 显式选择；无法求值或不支持的条件与语法不会被当成已证明声明。
- cjdoc 不猜无法唯一绑定的类型、`@see` 或章节目标，保留可见原文并给出 `unresolved`、`ambiguous` 或 `unavailable`。
- GitHub 源码 URL 只接受 `https://github.com/<owner>/<repo>` 形式且被引用源码必须位于该仓库根内；其他情况不会变成已验证链接。
- Windows 当前不实现站点本地图片的安全相对文件读取：图片被省略并报 `CJDOC4026`，Markdown 替代文本保留，生成可为 `partial`。Linux 与 macOS 支持该路径。
- `--locale` 不翻译作者正文。`versions compose` 只复制既有站点并注入选择器，不重新生成，也不校验各版本内容是否一致；每个版本输入须是有效 HTML 站点入口或带站点清单的多语言输出根。
- `render` 只接受当前的 `cjdoc.doc-ir/20`；源码或指南改动后要重新 `generate`。current-only 只针对 Doc IR，其他协议各自有版本，见[产物参考](artifacts.md#schema-与-wire-版本)。
- 声明、标签、源文件、辅助输入与渲染产物都受固定预算约束。超限时可能报诊断、跳过输入、保留部分结果或报资源错误；保留了一部分输出不等于全量成功，也不能靠调大上限绕过安全边界。

## 主要资源上限

下面是实现的固定界限，不是建议调大的性能参数。配置文件自身的解析上限见[配置参考](configuration.md)，示例沙箱限制见[文档注释参考](doc-comments.md#示例)。

| 对象 | 限制 | 达到限制后的含义 |
|---|---|---|
| 源码扫描 | 最多 100,000 个源文件；单文件最多 32 MiB；源码合计最多 512 MiB；目录遍历最多 100,000 项、深度 128；最多 4,096 个模块、16,384 条依赖边 | 停止或跳过后续输入并报诊断，输出不应被当作完整扫描 |
| 源码辅助输入 | 累计读取最多 512 MiB，累计工作最多 1 GiB；源码位置索引每文件最多 1,000,000 行 | 依赖清单、锁文件等可能不完整；过长文件被跳过，看具体诊断 |
| 源码缓存 | 单个缓存最多 64 MiB、最多 100,000 条目；默认目录 `target/cjdoc/cache/source-v11` | 缓存被拒绝或重建；`--no-cache` 关闭读写，但不解除源码扫描上限 |
| 并行度 | `--jobs` 只接受 `1..64`，默认 `1` | 越界是无效参数；增加并行不扩大总扫描预算 |
| Doc IR | `max-doc-ir-mib` 取 `1..64`，默认 64 MiB；单 JSON 字符串最多 24 MiB；最多 131,072 个 JSON 对象、147,456 个累计数组项；类型与 Markdown 嵌套深度各 64 | 输入超限是输入错误；生成超限保留有界回退并报 `CJDOC3027` |
| 本地栅格图片 | 每张最多 16 MiB、每边最多 16,384 像素、单张最多 100,000,000 像素；合计最多 64 MiB、200,000,000 像素 | 校验失败、路径不可安全读取或预算不足时省略并报 `CJDOC4026`；不从外部 URL 抓取 |
| 渲染产物 | 单产物最多 64 MiB；一次渲染合计最多 512 MiB、最多 65,536 项；输出清单 `.cjdoc-output.json` 最多 8 MiB | 触发渲染资源处理；generate 可能得到降级快照，单独 render 或无法满足预算时失败 |
| 概念文档 | 配置最多 64 KiB；单个源 Markdown 最多 256 KiB；概念页合计最多 128 页；每页最多 32 个 `cjdoc-bind` 标记 | 超限报配置错误或诊断，超出部分不生成 |
| 元数据 | `cjdoc.toml` 最多 64 KiB；group 与 tag 各最多 2,048 条；标题 1–256 字节 | 解析失败或诊断；见[配置参考](configuration.md) |
| 源码来源登记 | `cjdoc.toml` 最多 64 KiB；最多 4,096 条登记；receipt 文件条目合计最多 100,000 个；来源警告最多 4,096 条 | 超限报配置错误或把来源降为 `unavailable` |
| 外部文档 | 单个索引最多 8 MiB；`cjdoc.toml` 最多 64 KiB；库存合计最多 32 MiB；文档集最多 256 个 | 该来源不可用，API 内容仍保留 |
| 示例检查 | 单次最多 256 个示例；示例源码文件最多 32 MiB、合计 128 MiB；单次运行 10 秒、stdout/stderr 各 64 KiB、内存 2048 MiB | 超出部分不检查；运行限制触发 `CJDOC3073`/`CJDOC3075`/`CJDOC3074` |
| 高亮 | 单代码块最多 256 KiB、65,536 个 span；合计最多 8,192 个 span、4 MiB；外部适配器输入 2 MiB、输出 3 MiB | 保留纯文本并按 `on-error` 报 `CJDOC3120` 或 `CJDOC4027` |
| 多语言 | 同一次发布最多两种语言（`zh-CN`、`en`） | 更多语言不是可扩展清单，需缩减 |
| 版本合站 | 最多 64 个站点；合计最多 256 MiB、65,532 个文件；单份 diff 输入最多 32 MiB | 拒绝合站或 diff，不静默截断 |
| API diff 输入 | 每份快照最多 64 MiB | 拒绝读取 |
| Query / MCP | 请求最多 1 MiB、深度 64；快照 1–64 个；规范化 Doc IR 合计最多 64 MiB；资源加载累计最多 512 MiB；结果 envelope 最多 64 MiB；MCP 单条输入 1 MiB、工具 schema 8 MiB、响应外层 130 MiB | `budget_exceeded` 可按 retry 重试，`resource_limit` 表示硬上限 |

## 覆盖率与质量统计

`coverage/coverage.json` 的报告口径：

| 指标 | 分母 | 已文档 |
|---|---|---|
| 符号 | 可见声明 | 有非空摘要 |
| 参数 | 可见参数中不以 `_` 开头的 | 说明非空 |
| 返回值 | 有非 `Unit` 返回值的声明 | `@return` 非空 |
| throws | 实际记录的 `@throws` 条目 | 说明非空 |
| deprecated | 实际记录的 `@deprecated` 条目 | 弃用说明非空 |
| examples | 全部可见符号；没有注释的声明也计入 | 至少一个非空 `@example` |
| semanticLinks | 已记录语义链接（`@see` 与结构化 Markdown 链接） | 解析状态为 `resolved` |

每个分母为 0 时按 100% 报告。

`check --min-symbol-coverage`、`--min-parameter-coverage` 不是上面这套指标：它们只要求存在文档对象、存在参数文档对象，不要求摘要或说明非空。配置 `[coverage]` 门槛与这两个 CLI 门槛分别计算并同时执行；翻译覆盖率又是另一套「已配对字段」口径。三者不能互换。逐包门槛与规则严重级别见[配置参考](configuration.md)，操作步骤见[检查文档质量](../how-to/check-quality.md)。
