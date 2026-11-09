# 固定输入查询与 MCP 协议参考

`cjdoc query` 和 stdio MCP 都调用同一个只读查询核心。输入是明确提供的已捕获文档快照；查询不会扫描项目源码、重新解析依赖、选择/调用 SDK、运行 compiler、下载内容或访问网络。运行原生 `cjdoc` 仍需要其适配的仓颉运行时库。输入文件、CLI 产物和版本身份见[产物参考](artifacts.md)；query 的状态分层见[状态与限制](states-and-limits.md#查询完整性与状态)。

## CLI 与输入快照

`query` 需要 `1..64` 个显式 `--snapshot`，并恰好一个 `--request <文件|->`；`-` 表示从 stdin 读一个 UTF-8 JSON 对象。快照可为当前 Doc IR、HTML 文档根/`agent/manifest.json`，或已有版本目录的 `versions.json`。读取器启动时一次性装载这些输入，再在冻结快照上执行查询。

显式输入和 `versions.json` 中的语言、版本目录展开后，合计最多 64 个快照。所有快照的规范化 Doc IR 合计最多 64 MiB；加载清单、文档及其资源的累计读取量最多 512 MiB。这些是启动加载的总量限制，与单次请求的 `limit`、`maxBytes` 以及结果字节上限分别计算。

```bash
cjdoc query --snapshot <已生成的当前快照或机器清单> --request request.json
```

命令将一个 `cjdoc.query-result/4` JSON 对象写到 stdout，并返回与结果状态对应的退出码。参数/输入层面的 CLI 失败也会尽可能以相同的 result envelope 输出；MCP 启动/传输失败则写 stderr。请求最大 1 MiB、嵌套深度 64；不接受超过限额、损坏或含重复 JSON key 的请求。

## `cjdoc.query-request/3`

请求是严格 JSON object，只允许 schema 列出的属性；`operation` 必填，必须是 `resolve_docs`、`search`、`get_symbol` 之一。若提供 `schemaVersion`，必须为 `cjdoc.query-request/3`。未知键或操作不适用的字段不是“被忽略”的选项，会得到 `invalid_request`。

### 通用字段

| 字段 | 约束/意义 |
|---|---|
| `schemaVersion` | 可选；若提供，仅接受 `cjdoc.query-request/3`。 |
| `operation` | 必填：`resolve_docs`、`search`、`get_symbol`。 |
| `snapshotId` | 选定已加载文档快照；最多 256 字符。 |
| `language`、`languageFallback` | 阅读语言与是否允许语言回退；投影只使用已捕获作者变体。 |
| `audience` | `external`、`package`、`all`。 |
| `cfgProfile` | 所请求的捕获 cfg profile。 |

字符串字段的非空约束和长度上限由 `cjdoc schema query-request` 声明；下面的操作表说明字段是否适用于操作。`languageFallback`、`audience` 与 `cfgProfile` 的选择不能超出加载快照实际记录的 scope。

### 操作字段

| 操作 | 可用字段 |
|---|---|
| `resolve_docs` | `query`、`contextSnapshotId`、`contextModuleId`、`dependencyInstanceId`、`documentSetId`、`moduleId`、`packageName`、`apiVersion`、`library`、`target`、`cfg`、`latest`、`compatible`、`limit`、`cursor`、`maxBytes`。 |
| `search` | `query`、`symbolId`、`symbolKey`、`name`、`qualifiedName`、`parameterTypes`、`genericArity`、`kind`、`moduleId`、`packageName`、`documentSetId`、`apiVersion`、`library`、`dependencyInstanceId`、`target`、`cfg`、`latest`、`limit`、`cursor`、`mode`、`profile`、`filters`、`tags`。 |
| `get_symbol` 的 scope | `moduleId`、`packageName`、`kind`、`documentSetId`、`apiVersion`、`dependencyInstanceId`、`library`、`target`、`cfg`。 |
| `get_symbol` 的声明详情 | 身份选择器恰好一个：`symbolId`、`symbolKey`、`pageId`。声明支持 `preset`/`sections`、`maxBytes`；仅声明详情可加 `relations`、`relatedSnapshotIds`、`cursor`、`limit`。 |

`resolve_docs.query` 用于匹配库、模块、包；查符号使用 `search`，不要把声明名作为 resolve 的库/包语义。context 字段指向已载入的消费者/依赖快照，不重新解析依赖，也不会自动扩大目标候选的快照范围。`compatible` 是显式选择策略；`latest` 仅在输入 catalog 已声明 latest alias 时有效，缺失 alias 会返回 `unavailable`，不等价于任意选最新文件。

`search` 的通用选择/过滤字段可以组合收窄候选。`parameterTypes`、`genericArity`、`symbolId`、`symbolKey` 与结构化范围均使用已捕获身份，不会调用编译器判断调用适配性。

### 搜索筛选与分页字段

- `mode` 为 `precise` 或 `discovery`；原生查询默认 `precise`。`profile` 为 `full-ir` 或 `bounded-static`；原生默认 `full-ir`。
- `limit` 范围 `0..100`，默认 20。`0` 表示返回空页而不读取候选，不表示“没有声明”；仍可返回真实 `total`，且不会发出无进展 cursor。搜索 `total` 是 scope 与全部谓词下的去重候选数，不是当前页数量。
- `cursor` 是服务端返回的 opaque continuation；详见[游标绑定](#游标绑定与继续读取)。
- `filters` 最多 64 个 `{field, op, value}`，每条字段均必填。`field`：`name`、`qualifiedName`、`owner`、`param`、`return`、`package`、`kind`；`op`：`eq`、`contains`；`value` 为 1–16384 字符。多个条件 AND。`eq` 大小写敏感；`contains` 只折叠 ASCII `A`–`Z`，不作 Unicode normalization 或 locale 大小写折叠。参数针对单个参数值匹配，不把多个参数合并。
- `tags` 为 1–64 个分类 ID 的数组；ID 为 1–64 个 ASCII 字母、数字、`-`、`_`，大小写敏感且精确相等。重复项去重并规范化排序；多个 ID 是 AND。省略表示不筛标签，空数组非法。标题、正文提及或 ID 前缀不是 tag 成员关系；concept 页没有 tag 集合。

没有文字 query，但有有效 scope、filter、tag 或 overload selector 时会枚举满足条件的结果，匹配原因 `filter_only`、score 0。完全没有文字或有效条件时为空结果；仅给 `mode`、`profile`、`limit`、`cursor`、`languageFallback` 或 `latest:false` 不触发枚举，执行器补齐的默认范围也不算显式 filter。

### `get_symbol` 章节与预算

选择器必须是 `symbolId`、`symbolKey`、`pageId` 之一且仅一个。`preset` 和 `sections` 互斥；`sections` 必须是 1–11 个不同章节。声明章节及输出顺序：`signature`、`parameters`、`returns`、`contracts`、`examples`、`description`、`relations`、`source`、`diagnostics`、`validation`、`diff`。

| preset | 内容 |
|---|---|
| `summary` | `signature` 与 `description`。 |
| `call` | `signature`、`parameters`、`returns`、`contracts` 为必要调用信息；`examples` 尽量在预算内加入。 |
| `reference` | 所有受支持章节。 |

未提供 preset/sections 时使用全部声明章节。概念页的 `pageId` 只能使用 `summary` 或 `reference`；可请求章节限于 `description`、`source`、`validation`、`diff`，不能用调用预设或声明的签名/关系章节。未请求的内容不会被静默改写为摘要；各章节通过 `state` 表达实际情况。

`maxBytes` 范围 1 KiB–64 MiB，默认 65,536 字节，预算覆盖章节正文和结构化值，不是模型 token 数保证。无法放入必要调用信息时返回 `budget_exceeded`，附真实 `requiredBytes` 和可行 retry；可选章节按完整章节省略。硬资源限制无法满足则为 `resource_limit`，不能通过重复请求要求不存在的完整内容。核心 result JSON 的 64 MiB 限制独立于 `maxBytes`。

关系展开参数 `relations`：`direction` 为 `outgoing`、`incoming`、`both`（默认 both）；`kinds` 最多 32 个关系种类字符串，省略或空集表示不限 kind；`depth` 默认 1、范围 `0..4`；`limit` 默认 25、范围 `0..100`。仅遍历快照中已捕获的关系，并按准确 `(snapshotId, symbolId)` 去环。关系章节深度/数量为 0 会返回明确省略理由；深度截断提示提高 depth（最多 4），数量/字节截断时提供关系遍历 cursor。额外快照只能通过最多 64 个 `relatedSnapshotIds` 显式选择；跨 root/dependency 不能凭裸本地 Symbol ID 合并。

## 搜索匹配合同

`precise` 优先声明身份和高置信标识：精确 `symbolId`/`symbolKey`、限定名、声明名、owner-member、重导出别名，再到标识符或文档 token。参数/返回类型不扩展 precise 自由文本范围，但可以通过结构化条件筛选。若最高证据等级有多个候选，返回 `ambiguous`，不按哈希遍历顺序挑重载。

`discovery` 用分数排序并可同时返回多个候选：

| 分值 | 证据 |
|---:|---|
| 12000 | 精确 `symbolId` 或 `symbolKey`。 |
| 11000 | 精确 qualified name。 |
| 10000 | 精确声明名、owner-member 或可见 alias。 |
| 9000 / 8000 / 7000 | ASCII 折叠名称 / 名称前缀 / qualified-name 前缀。 |
| 6000 / 5000 | 所有 query token 的词前缀 / acronym。 |
| 4000 / 3000 | 结构化声明文本 / 一个 token 的一次编辑距离。 |
| 2000 | 文档正文或概念正文。 |
| 0 | 仅用 scope、filters、tags 枚举（`filter_only`）。 |

`full-ir` 使用捕获的完整正文；`bounded-static` 每条记录只索引正文前 2,000 个 Unicode 码点，身份、参数、返回和分类字段不截断。摘要展示预览最多 240 码点，签名预览最多 512 码点；截断时省略号计入限长。匹配不按 UTF-8 字节截断。原生 query 可选两种 profile；HTML 静态索引只提供 `bounded-static`，只提供 `search`，不能执行 `resolve_docs` 或 `get_symbol`，请求 `full-ir` 返回 `unavailable/search_profile_unavailable`。

检索只做 ASCII 大小写折叠，不做 NFC/NFKC 或非 ASCII 大小写折叠。token 由 ASCII 字母、数字、下划线及 U+0080 以上码点组成；其他字符分隔 token。camelCase/acronym 分界只识别 ASCII 大小写边界。一次编辑距离只对 4–128 码点单 token 开放，允许单次插入、删除或替换，不含转置。纯标点 query 不产生 token，但仍可按名称折叠/前缀规则匹配；token 规则不会把空 token 当成匹配全站。

结果以 `(snapshotId, canonical symbol/page ID)` 去重；不同 snapshot、module、owner 或 origin 不合并。排序按 score 降序，再按 snapshot ID、canonical ID、reason 的 UTF-8 字节顺序稳定排列。精确等级并列依旧是 `ambiguous`。`result.facets.tags` 按当前全部过滤条件统计可见 canonical declarations；分域保留 snapshot/module/dependency 身份，不计 exposure 或隐藏声明。筛选和显示标签使用 ID，而非标题。`coverage` 会显示运行的 profile、projection ID、body text 限长、正文完整性和被截断条目数；静态索引未覆盖文本不能据此证明不存在匹配。

## 结果 `cjdoc.query-result/4`

所有操作返回相同 envelope，必含：

| 字段 | 含义 |
|---|---|
| `schemaVersion` | 恒为 `cjdoc.query-result/4`。 |
| `status`、`operation` | 查询域状态与操作名。 |
| `scope` | `requested` 原始请求、`catalogId`（加载内容身份）及每个已选快照的身份/来源/语言/audience/api collection state/publication revision/`packagedRepresentations`。 |
| `selection` | `resolve_docs` 的策略、已选项和候选；其他操作通常为 null。 |
| `result` | 始终含 `items`、`relations`、`reports`、`facets`。`resolve_docs` 的 items/relations/reports 为空；非搜索 facets.tags 为空。 |
| `completeness` | 分开记录 API 捕获、当前查询分页与返回内容是否完整。 |
| `sources` | 被选输入的源码路径、可用 URL 和 captured state；缺 URL 不代表无源码。 |
| `text` | 与 envelope 对应的人类可读说明，不能替代结构化字段。 |
| `error` | 普通领域结果为 null；请求/资源等执行失败时为结构化 code/message/requiredBytes/maximumBytes（数值字段可为 null）。 |

`items[].identity` 提供 snapshot/source snapshot、document set、module、dependency instance、symbol/page 身份。优先原样保留 ID/key；不要从截短摘要猜身份。只装载 Doc IR 时 `packagedRepresentations=false`，规范路由不是资源随包复制的证明；完整正文仍可用 `get_symbol` 读取。装载 machine manifest 才会验证其资源 hash 与完整表示映射。

`completeness` 有三个不相互替代的维度：

1. `apiCollection` 每个 snapshot 报 `resolved`、`partial` 或 `unavailable`，说明源 API 捕获完整度，独立于当前查询 top-k。
2. `query` 报 `scope`（`catalog`、`declaration`、`page`、`relations`、`document_sets` 或空串）、offset、returned、total（未知时 null）、next、reason、coverage。`complete:true` 时 `next` 必须为 null；存在 `next` 时 `complete:false`。relations scope 的 returned 是关系条数，不是重复的主体声明数。
3. `content` 报 `complete`、`selectedSections`、`omittedSections`、`missingSections` 和 `retry`。每个章节状态可为 `available`、`missing`、`not_selected`、`budget_omitted`、`unavailable`；它们分别表达来源可用、原输入缺项、未请求、预算省略或证据不可用，不要合并成空字符串。

`result.reports` 中 validation/diff 是附加报告原文和绑定信息。`not_attached` 不是通过；附着本身也不证明报告生产者可信。报告身份/hash、快照和配置未绑定时应保留 binding unavailable/mismatch；源码存在、站点构建成功、诊断缺失都不等于执行回执。

## 状态与 CLI 退出码

| `status` | CLI 退出码 | 解释 |
|---|---:|---|
| `ok` | 0 | 请求的查询成功。 |
| `ambiguous` | 0 | 候选不能唯一决定；这是正常域结果，调用方需按身份缩小 scope。 |
| `not_found` | 0 | 在已加载且可见的完整捕获 scope 中没有匹配；不等于整个上游库不存在。 |
| `source_incomplete` | 0 | 捕获不完整，不能从未命中推断全库不存在。 |
| `invalid_request` | 2 | JSON、schema、字段适用性或字段值错误。 |
| `scope_mismatch` | 2 | 指定快照、language/audience/cfg 或身份 scope 不在加载集合中。 |
| `stale_cursor` | 2 | cursor 格式错误、绑定不匹配或偏移越界。 |
| `budget_exceeded` | 3 | 必要内容超过用户预算，可按 `requiredBytes` 重新发起。 |
| `resource_limit` | 3 | 硬资源/输出上限不允许完成请求。 |
| `unavailable` | 3 | 所需证据/输入/可选能力不可用。 |

`not_found` 与 `scope_mismatch` 不同：前者表示 scope 被正确选中但候选不存在；后者表示请求的 scope 不在已载入 catalog/projection。若 source collection 为 partial/unavailable，即使没有候选也不能当作完整未命中，状态应指明 `source_incomplete`。

## 游标绑定与继续读取

查询 continuation 使用 `cjdoc.cursor/2` opaque token。不要手工构造、解析或把它当作认证凭据。Token 绑定冻结输入内容/catalog、projection、profile，以及除 `cursor` 外的规范化完整请求：scope、query、mode、filters、tags、排序条件、语言、fallback、受众、limit/预算等都属于绑定。filters/tags 的顺序和重复项会先规范化。

续页时只把响应 `completeness.query.next` 或关系返回的 cursor 原样放回同一请求，其余字段保持不变。改变输入、范围、查询条件、模式、profile、limit、语言或预算，必须去掉 cursor 从第一页重查；旧 token 会返回 `stale_cursor`，不会把不同查询的观察混合。若 `get_symbol` 必要部分超过预算，使用新预算并去掉旧 cursor 重查；不能一边换预算一边续旧页。

关系遍历的 cursor 只继续同一个 frozen relation walk。`relations.depth` 截断使用 omission/retry 说明增加深度，而非声称已经枚举完图；超过最大深度 4 或硬限制时没有更深的受支持入口。

## 本地 stdio MCP

MCP 是可选读取适配，不是生成、静态站或普通 CLI query 的前提。启动时传入同一组固定快照：

```bash
cjdoc mcp --snapshot <已生成的当前快照或机器清单>
```

传输遵循 MCP 2025-11-25 stdio：一行一个 UTF-8 JSON-RPC 2.0 object，stdout 只用于协议消息。一个 server 对应一份加载完成的冻结 query session。

### 生命周期与状态

1. Client 发送一次 `initialize` request，需含 `protocolVersion`、object `capabilities`、`clientInfo.name` 和 `clientInfo.version`。
2. Server 回报实现的协议版本 `2025-11-25`、tools capability、server info 和说明；随后 client 必须发送 `notifications/initialized`。
3. 收到初始化通知后进入 ready，可调用 `tools/list`、`tools/call`。在 ready 前调用这两项返回 JSON-RPC `-32600`（未初始化）；再次 initialize 也返回 `-32600`。
4. 支持的 tools 固定为 `resolve_docs`、`search`、`get_symbol`；`tools/list` 不分页，不接受 cursor。tool arguments 直接是对应 operation 的字段，不能传 `operation`，工具名决定 operation。
5. stdin EOF 是 stdio 的正常关闭，没有 shutdown RPC。空行忽略；CRLF 接受；单个 JSON-RPC batch 不支持。Notification 无论有无效参数都不回复；初始化通知只在已协商后使 server ready。

`tools/call` 结果的 `structuredContent` 是完整 `cjdoc.query-result/4` envelope；`content[0].text` 是同一 envelope 的 `text` 字段。`isError` 只对 `ok`、`ambiguous`、`not_found`、`source_incomplete` 为 false；其它已知 query statuses 是 tool execution error，但仍以正常工具结果结构返回，而不是 JSON-RPC protocol error。换言之，领域查询失败仍能读取它的完整状态/错误 envelope。

### MCP 错误分层与资源限制

JSON-RPC/协议层错误码：`-32700` parse error；`-32600` invalid request（包含尚未 ready）；`-32601` method not found；`-32602` invalid params；`-32603` internal error。未知工具、tool 参数非 object、重复传 `operation`、无效 initialization 参数属于协议/tool 调用层错误。请求字段/查询 scope/预算问题则由 query core 的 `cjdoc.query-result/4` 状态报告，不与 JSON-RPC 错误混淆。

MCP 每条输入最多 1 MiB、JSON 深度 64；查询请求自身也最多 1 MiB。工具 schema 最多 8 MiB；响应外层最多 130 MiB，包含完整结果 `structuredContent`、可读 `content[0].text` 和 JSON-RPC 封装。可读文本来自结果的 `text` 字段。正常 CLI query 仅返回核心 envelope；MCP 外层上限、核心结果上限和用户 `maxBytes` 是独立限制。

客户端配置还需要正确传递 cjdoc 动态运行时库搜索路径；若客户端/进程不能继承环境，应在其 MCP server 配置里显式设置平台运行时路径。Codex CLI 0.163 的 MCP 调度还依赖配套 `codex-code-mode-host`，这是客户端前提，不代表 cjdoc 已被模型调用或启用 shell/网页工具。