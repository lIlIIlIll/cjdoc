# 状态与限制参考

本页集中说明阅读和发布结果中的状态词、输入可见范围、语义与来源证据边界，以及当前源码实施的资源上限。状态字段属于不同维度，不能把同一个英文词在不同对象里的含义互相替代。命令选项和退出码见[CLI 参考](cli.md)；配置级限制见[配置参考](configuration.md)，注释和示例限制见[文档注释参考](doc-comments.md)，查询专用状态与预算见[Query 协议](query-protocol.md)。

## 结果完整性不是单一布尔值

生成快照至少要区分发布状态与 API 收集状态：

| 字段 | 当前值 | 含义 |
|---|---|---|
| `status` | `complete`、`partial` | 整体文档输入、语义处理和发布是否有不完整项。诊断错误、不可用/歧义语义能力、孤立注释、宏调用、未支持声明或未绑定语义声明，不能与 `complete` 并存。 |
| `apiCollectionState` | `resolved`、`partial`、`unavailable` | API 收集范围是否完整；它独立于页面、lint、highlight 等发布诊断。 |

例如，API 可以完整收集（`apiCollectionState = resolved`），但可选高亮后端失败使生成状态为 `partial`；反过来，不能仅凭一份有 HTML 文件的输出推断 API 收集完整。遇到 `partial` 时，查看生成诊断和 `apiCollectionState`，再决定这份快照是否适合用作覆盖率、严格基线、外部链接或查询范围。查询还会报告独立的枚举与内容完整性，不得把“当前页没有结果”读成“整个 API 都没有此项”。

## 查询完整性与状态

Query envelope 将 API 收集、候选枚举和返回内容分开记录：`completeness.apiCollection` 不受当前页 `limit` 影响；`completeness.query` 记录 scope、offset、returned、total、complete、next 和 coverage；`completeness.content` 记录已选、缺失、因预算省略的章节及 retry。`total = null` 表示未知，不等于零；未执行查询时 coverage 为空，不能推断“已完整搜索”。关系续取的 scope 是 `relations`，returned 计关系而不是重复的主体声明。

Query 领域结果状态 `ok`、`ambiguous`、`not_found`、`source_incomplete` 是正常查询响应；其中 `not_found` 只在声明的快照/范围内未找到，`source_incomplete` 表明输入 API collection 本身不完整。`invalid_request`、`scope_mismatch`、`stale_cursor` 是请求或固定范围不成立；`budget_exceeded`、`resource_limit`、`unavailable` 表示内容预算、硬资源限制或输入可用性问题。CLI 退出码分层及 MCP JSON-RPC 协议错误见[Query 协议](query-protocol.md)。

## 解析、匹配与语义状态

相同词汇可能附着在引用、导航、契约或收集字段上；先识别状态属于哪个字段。

### 语义信息与类型导航

| 状态 / 匹配级别 | 含义与使用边界 |
|---|---|
| `resolved` | 找到唯一可用目标。仍须阅读附带的匹配级别、来源和原因；对于外部依赖不等于行为证明。 |
| `unresolved` | 在声明的输入和选择范围内没有唯一可用目标。它不是“目标在整个生态中不存在”的证明。 |
| `ambiguous` | 有多个同优先级或冲突候选；不能任取一个链接。 |
| `unavailable` | 目标可能存在，但当前证据、可见范围、输入、资源预算或所选依赖上下文不足以安全解析。它与 `unresolved` 的根因不同。 |
| `partial` | 部分语义信息可用，但不能当作完整解析；它是语义对象状态，不是 `TypeNavigation.state` 的有效值。 |


`TypeNavigation.state` 仅有 `resolved`、`unresolved`、`ambiguous`、`unavailable`；语义对象/类型状态还可为 `partial`。不要把不同模型字段的允许值混为同一枚举。

依赖文档导航的 `matchLevel` 另为 `exact`、`compatible`、`manual` 或 `none`：

- `exact` 要求被消费的依赖身份、已 pin 的外部库存、发布文档集身份及可匹配的来源/依赖上下文等证据符合实现条件。它表示输入证据之间匹配，不认证网站托管者，不证明发布者 API/ABI 真实，更不证明消费者运行正确。
- `compatible` 表示存在显式的 API/构建上下文兼容映射；映射和托管地址是声明，不是远端认证。
- `manual` 是作者指定但证据不足以自动建立身份关系的参考。显式旧式 `/1` 索引 URL 也可能以 `resolved/manual` 输出；不要把它升级成 exact。
- `none` 表示没有匹配级别，通常与非 resolved 状态一起出现。

本地且处于所选模块依赖上下文中的权威目标可以是 `resolved/exact`。当目标被 audience 排除、同名依赖候选冲突、源码 `import` 无法排除隐式 `std.core` 歧义，或导航工作预算耗尽时，结果会保留为 `unavailable` 或 `ambiguous`，而不是猜测。读者检查某个结果时，应同时看 `state`、`matchLevel`、`reason`、目标身份和 URL；仅有 URL 字符串不是身份证据。

API 契约快照中，类型/default/返回值等契约字段可以是 `resolved`、`partial`、`unavailable`、`ambiguous`；基线与当前声明匹配状态是 `exact`、`fallback`、`ambiguous`、`added`、`removed`。比较结论也有独立分类 `breaking`、`potentially-breaking`、`additive`、`documentation-only`、`metadata-only`、`unchanged`。如果收集状态不完整或字段不可解析，diff 不应把不确定信息包装成“无变化”；详细输入条件见[比较与多版本](../how-to/compare-and-version.md)。

## 来源和外部文档证据

### 源码来源 `provenance`

Doc IR 的每个源文件记录来源状态：

| 状态 | 能证明什么 | 不能证明什么 |
|---|---|---|
| `verified` | 已登记仓库和调用者独立 pin 的回执与捕获源码字节匹配；带来源仓库、相对路径、摘要及 `caller_pinned_receipt` 证据。 | 不单独认证 Git commit/tree、远端仓库、构建是否成功、工作树是否干净，或调用者为何信任该 pin。 |
| `declared` | 由旧式项目仓库信息映射出的仓库/路径声明。 | 没有文件摘要和回执 pin，不是已验证来源。 |
| `unavailable` | 当前没有可用的来源证明；原因字段说明具体缺失或失败。 | 不应据此构造 GitHub 源码 URL。 |
| `ambiguous` | 仓库登记相互冲突。 | 不可任选一个仓库或路径。 |

只有有效源码范围上的 `verified` 或旧映射 `declared` 来源才可能投影为源码 URL；后者仍只是声明链接。离线重放会保留快照内的状态和证据字段，不重新打开源码、Git 或回执，也不重新验证 pin。面向读者时，引用重导出符号的**暴露位置**与目标声明的**定义来源**是两个字段，不能混为一谈。

### 外部文档引用

外部文档快照的状态为 `available`、`unavailable`、`ambiguous`；后两者没有可用 URL。`available` 只说明当前本地索引选择能提供一个链接目标，不自动证明它对应项目实际解析到的依赖版本。完整的外部库存、版本、依赖图和 pin 条件见[链接外部文档](../how-to/link-documentation.md)。标准库文档 URL 只是阅读参考；它不证明当前项目 SDK 中的类型与该 URL 所指版本一致。

## 多语言与诊断状态

### 注释翻译

Doc IR 的 `translationState` 可为 `complete`、`fallback`、`empty-fallback`、`conflict-fallback`、`empty`、`conflict`、`missing`、`unknown`、`unpaired`（或未设置的空串）。读者应结合 `contentLanguage`、请求的 `readingLanguage` 和字段本身判断：

- `complete`：请求语言的有效字段可用。
- `fallback`：显示了其他可用语言的有效文本，通常来自输入默认语言或唯一可证明的配对译文；正文仍标明实际来源语言，不计为请求语言的完整译文。
- `empty-fallback`：请求语言字段存在但为空，因而回退显示有效原文；空译不会算成完成译文。
- `conflict-fallback`：请求语言定义冲突，保留冲突事实并回退到有效原文，不以最后一条覆盖前一条。
- `empty`、`conflict`、`missing`：分别表示空字段、同语言重复冲突、缺少请求语言字段；缺译不会删除 throws、弃用状态等 API 事实。
- `unknown`：输入缺少可确认的正文语言信息。
- `unpaired`：无法唯一证明跨语言条目关系，按独立条目保留，不按顺序、标题或位置猜测配对。

语言发布目前限 `zh-CN` 与 `en`，不自动翻译；`--locale` 选择界面和已有作者译文，不生成新译文。完整配对算法、缺译回退和诊断码见[文档注释参考的多语言规则](doc-comments.md#多语言注释)。

### 指南绑定

`DocumentationPageBinding.state` 的取值是 `resolved`、`unresolved`、`ambiguous`、`unavailable`、`conflict`：只有 `resolved` 才有已绑定的目标 SymbolId；其他状态保留未绑定/歧义/不可用/冲突事实，不会凭文本自动关联某个 API。其导航状态与绑定状态分开记录。指南 ID 和语言决定页面配对，标题相同本身不构成身份；配置、章节映射和提示语法见[配置参考](configuration.md)与[添加指南](../tutorials/add-guides.md)。

## 可见范围与快照身份

`--audience` 控制面向读者的声明投影：`external` 是 `public`/`protected`，`package` 包含除 `private` 外的声明，`all` 包含全部声明。嵌套声明也要满足其 owner 的可见范围。此选项是文档视图/契约比较范围，不是访问控制、源码过滤或保密边界；尤其不能把 `docs.json` 当成已按 audience 脱敏的数据，Doc IR 快照会保留捕获模型及配置中的 audience。发布前不要把含内部/私有源码事实的 JSON 交给不受信任的读者。

读取语言、audience、项目/模块身份、目标与 cfg 等上下文会影响阅读视图、依赖导航、快照匹配和查询 cursor。`documentationRevision` 是文档发布标签，不改变 API 源码或依赖版本。比较不同版本前，应分别从对应源码生成快照，见[比较与多版本](../how-to/compare-and-version.md)。

## 能力边界

- 普通源码生成、检查和离线渲染不下载依赖、不下载标准库文档、不访问外部文档站；依赖和索引须由使用者预先准备。查询和 MCP 只消费已捕获快照，也不扫描源码、选择 SDK、编译消费者或联网。
- 默认 `--semantic source` 收集源码可见信息，不会为了普通生成编译被扫描项目。它不读取编译器 target profile，也不自动展开宏；需要其他条件配置时用 `--cfg NAME=VALUE` 明确选择。无法求值/不支持的条件或语法不能被当成已证明声明。
- CHIR 是显式的可选语义补充，要求匹配的本机 compiler/worker 配置；缺失或失败时保留源码/AST 信息并给出诊断，不应把 CHIR 字段解释为权威的完整类型检查。配置步骤见[CHIR 语义补充](../how-to/chir.md)。
- cjdoc 不猜无法唯一绑定的类型、`@see` 或章节目标；保留可见原文并给出 `unresolved`、`ambiguous` 或 `unavailable` 状态。
- GitHub 源码 URL 仅接受 `https://github.com/<owner>/<repo>` 仓库根形式，且被引用源码必须位于该仓库根内。非 GitHub URL、仓库根外路径或不可信来源不会变成经验证的源码链接。
- Windows 当前不提供用于捕获站点本地图片的安全相对文件读取实现；图片会被省略并报告 `CJDOC4026`，其 Markdown 替代文本仍保留，生成可为 `partial`。Linux 与 macOS 支持该读取路径。图片格式和大小上限见下表。
- `--locale` 不翻译作者正文；`versions compose` 只复制既有站点并注入选择器，不重新生成，也不验证各版本实际内容是否一致；每个版本输入须是有效 HTML 站点入口或带站点清单的多语言输出根。
- `render` 只接受当前 Doc IR `cjdoc.doc-ir/18`。它不会重新扫描项目或读取当前配置/依赖；源码或指南变更后重新 `generate`。这条 current-only 限制只属于 Doc IR，不适用于所有 JSON 索引或协议 schema；各产物版本见[产物参考](artifacts.md)。
- 声明、标签、源文件、辅助输入和渲染产物均受固定预算约束。超过限制时可产生诊断、跳过输入、保留部分结果或报告资源错误；不能把“保留了一部分输出”称为全量成功，也不应通过增大上限绕过安全限制。

## 主要资源上限

以下是当前实现中的固定界限，不是建议用户调大的性能参数。配置文件自身的解析上限和示例执行沙箱限制分别见[配置参考](configuration.md)与[文档注释参考](doc-comments.md#示例)。

| 操作 / 对象 | 当前实现限制 | 达到限制后的含义 |
|---|---|---|
| 源码目录扫描 | 最多 100,000 个源码文件；单文件最多 32 MiB；合计源码最多 512 MiB；目录遍历最多 100,000 项、深度 128；最多 4,096 个模块、16,384 条依赖边。 | 超限会停止或跳过后续输入并报告诊断；输出不应被当作完整扫描。 |
| 源码辅助输入 | 辅助文件读取累计最多 512 MiB，累计处理工作最多 1 GiB；源码位置索引每文件最多 1,000,000 行。 | 依赖清单、锁文件等辅助数据可能不完整；过长源码文件会跳过，查看具体诊断。 |
| 缓存 | 单个 source cache 最多 64 MiB、最多 100,000 条目；默认缓存目录 `target/cjdoc/cache/source-v11`。 | 缓存超限/无效时按实现拒绝或重建；`--no-cache` 可关闭读取和写入，不会解除源码扫描上限。 |
| 生成并行度 | `--jobs` 只接受 `1..64`，默认 `1`。 | 超范围是无效命令参数；更多并行 worker 不会扩大总扫描预算。 |
| 本地栅格图片 | 每张最多 16 MiB、每张每边最多 16,384 像素、单张最多 100,000,000 像素；所有图片总计最多 64 MiB、200,000,000 像素。 | 图片校验失败、路径不可安全读取或预算不足时会省略，并报告 `CJDOC4026`；不从外部 URL 抓取图片。Windows 的捕获边界见上节。 |
| 每个渲染产物 | 最多 64 MiB；一个 render 收集的全部产物最多 512 MiB、最多 65,536 项。 | 超限会触发渲染资源处理；generate 有界回退时可能得到降级/partial 快照，单独 render 或写入无法满足预算时会失败。 |
| 多语言 | 同一次语言发布最多两种语言（当前支持 `zh-CN` 与 `en`）。 | 多于两种语言不是可扩展清单，需按当前支持范围配置。 |
| 版本合站 | 最多 64 个站点输入；合计最多 256 MiB、65,532 个文件；单份 diff 输入最多 32 MiB。 | 超出限制时拒绝合站或 diff，不会静默截断后继续宣称完整。 |
| Query / MCP | Query 请求、结果、游标和 MCP JSON-RPC 另有独立字节、数量、深度和续取边界。 | 具体默认/最大值、`budget_exceeded` 与 `resource_limit` 语义见[Query 协议](query-protocol.md)。 |

## 覆盖率与质量统计

`coverage/coverage.json` 的报告统计中，符号计入分母但只有非空摘要算已写文档；参数只计非 `_` 开头的参数，且说明非空才算已写；返回值只计非 `Unit` 返回；throws 与 deprecated 按实际记录的标签逐条计；examples 以所有可见符号为分母，即使声明没有注释也计入；semanticLinks 汇总 `@see` 与结构化 Markdown 语义链接，只有解析状态为 `resolved` 才算已解析。每个分母为零时报告 100%。

CLI 临时门槛 `check --min-symbol-coverage` / `--min-parameter-coverage` 不是上述报告指标：它分别以存在文档对象、存在参数文档对象作为已绑定条件，不要求摘要或说明非空。配置 `[coverage]` 与这两个 CLI 门槛会分别计算并同时执行；翻译覆盖率另有已配对字段的统计口径，三者不能互换。质量规则详细表与按包门槛见[配置参考](configuration.md)及[质量检查操作指南](../how-to/check-quality.md)。
