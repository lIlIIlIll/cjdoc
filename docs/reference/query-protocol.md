# 固定输入查询与 MCP 协议参考

`cjdoc query` 与 `mcp` 共用一个只读查询核心，输入是显式给出的已捕获文档快照。查询不扫描项目源码、不重新解析依赖、不选择或调用 SDK、不运行编译器、不下载内容、不联网。运行原生 `cjdoc` 本身仍需要其适配的仓颉运行时库。

请求字段定义见 `cjdoc schema query-request`（`cjdoc.query-request/4`），结果字段定义见 `cjdoc schema query-result`（`cjdoc.query-result/5`）。产物与 wire 版本见[产物参考](artifacts.md)，域状态分层见[状态与限制](states-and-limits.md#查询完整性与状态)。

## 快速索引

| 你要查 | 字段或操作 | 详见 |
|---|---|---|
| 某个库、模块、包是否在快照里 | `resolve_docs` | [各操作的可用字段](#各操作的可用字段) |
| 某个符号或文字 | `search` + `query`、`mode`、`filters`、`tags` | [搜索、筛选与分页](#搜索筛选与分页) |
| 声明的签名、参数、示例、关系 | `get_symbol` + `preset`、`sections`、`maxBytes` | [`get_symbol` 的章节与预算](#get_symbol-的章节与预算) |
| 下一批结果 | `cursor` 与 `completeness.query.next` | [游标与继续读取](#游标与继续读取) |
| 编辑器里的工具调用 | `mcp` 的 `tools/list`、`tools/call` | [本地 stdio MCP](#本地-stdio-mcp) |
| 结果为什么是这个状态 | `status` 与 `error.code` | [状态与退出码](#状态与退出码) |

## CLI 与输入快照

```bash
cjdoc query --snapshot target/doc/docs.json --request request.json
```

- `--snapshot` 给 1–64 个显式路径，可以是当前 `docs.json`、HTML 文档根下的 `agent/manifest.json`，或版本目录的 `versions.json`。`versions.json` 会按其版本目录展开。
- `--request` 恰好一个，`-` 表示从 stdin 读一个 UTF-8 JSON 对象。
- 命令把一个 `cjdoc.query-result/5` 对象写到 stdout，退出码由结果 `status` 决定。
- 参数或输入层面的失败仍尽量用同一个 result envelope 输出；`mcp` 的启动/传输失败写 stderr。

启动加载的总量限制：展开后快照合计最多 64 个；规范化 Doc IR 合计最多 64 MiB；加载清单、文档及其资源的累计读取量最多 512 MiB。这些与单次请求的 `limit`、`maxBytes`、结果字节上限分别计算。请求本身最多 1 MiB、嵌套深度 64，不接受超限、损坏或含重复键的 JSON。

## 请求 `cjdoc.query-request/4`

请求是严格 JSON object，只允许 schema 列出的字段。`operation` 必填，取 `resolve_docs`、`search`、`get_symbol`；若给出 `schemaVersion`，必须是 `cjdoc.query-request/4`。未知键返回 `invalid_request`（`unknown_field`），字段与操作不匹配返回 `invalid_request`（`field_not_applicable`）。

### 通用字段

| 字段 | 类型与范围 | 含义 |
|---|---|---|
| `schemaVersion` | 常量 `cjdoc.query-request/4` | 可选 |
| `operation` | `resolve_docs`、`search`、`get_symbol` | 必填 |
| `snapshotId` | 字符串 1–256 | 选定已加载快照 |
| `language` | 字符串 1–64 | 阅读语言 |
| `languageFallback` | 布尔 | 是否允许语言回退 |
| `audience` | `external`、`package`、`all` | 阅读受众 |
| `cfgProfile` | 字符串 1–16384 | 请求的捕获 cfg profile |

`language`、`audience`、`cfgProfile` 的选择不能超出加载快照实际记录的 scope；超出返回 `scope_mismatch`。

### 各操作的可用字段

| 操作 | 允许的字段 |
|---|---|
| `resolve_docs` | 通用字段 + `query`（≤4096）、`contextSnapshotId`、`contextModuleId`、`dependencyInstanceId`、`documentSetId`、`moduleId`、`packageName`、`apiVersion`、`library`、`target`、`cfg`、`latest`、`compatible`、`limit`、`cursor`、`maxBytes` |
| `search` | 通用字段 + `query`（≤4096）、`symbolId`、`symbolKey`、`name`、`qualifiedName`、`parameterTypes`（≤1024 项）、`genericArity`（0–1024）、`kind`、`moduleId`、`packageName`、`documentSetId`、`apiVersion`、`library`、`dependencyInstanceId`、`target`、`cfg`、`latest`、`limit`、`cursor`、`mode`、`profile`、`filters`、`tags`、`commentFields`、`commentFieldFacets` |
| `get_symbol`（范围） | 通用字段 + `moduleId`、`packageName`、`kind`、`documentSetId`、`apiVersion`、`dependencyInstanceId`、`library`、`target`、`cfg` |
| `get_symbol`（身份） | `symbolId`、`symbolKey`、`pageId` 三者恰好一个 |
| `get_symbol`（内容） | `preset` 或 `sections`（互斥）、`maxBytes`；`relations`、`relatedSnapshotIds`、`cursor`、`limit` |

`resolve_docs.query` 只用于匹配库、模块、包；查符号用 `search`。context 字段指向已加载的消费者/依赖快照，不重新解析依赖，也不会自动扩大候选范围。`latest` 只沿输入 catalog 明示的 latest alias 选择；独立快照没有该别名但仍有多个候选时返回 `ambiguous`（退出 `0`），`selection.selected` 为空，不猜最新文件。`compatible` 是显式选择策略。

### 搜索、筛选与分页

| 字段 | 范围与默认 | 说明 |
|---|---|---|
| `mode` | `precise`（默认）、`discovery` | 匹配策略 |
| `profile` | `full-ir`（默认）、`bounded-static` | 正文索引范围 |
| `limit` | `0..100`，默认 `20` | `0` 返回空页但不读候选，仍可给出真实 `total` 且不发 cursor |
| `cursor` | 1–1024 | 服务端返回的 opaque 继续标记 |
| `filters` | 最多 64 条 `{field, op, value}` | 三字段都必填；`field` 取 `name`、`qualifiedName`、`owner`、`param`、`return`、`package`、`kind`；`op` 取 `eq`、`contains`；`value` 长 1–16384；多条之间取 AND |
| `tags` | 1–64 个 ID | ID 为 1–64 个 ASCII 字母、数字、`-`、`_`，大小写敏感精确相等；多项取 AND；空数组非法 |

`eq` 大小写敏感；`contains` 只折叠 ASCII `A`–`Z`，不做 Unicode 规范化或 locale 折叠。参数条件针对单个参数值，不把多个参数合并。标签按完整 ID 匹配，标题、正文提及或 ID 前缀都不是成员关系。

没有文字 query，但有有效 scope、filter、tag 或重载选择器时，会枚举满足条件的结果，`match.reason` 为 `filter_only`、分值为 0。完全没有文字也没有有效条件时返回空结果。只给 `mode`、`profile`、`limit`、`cursor`、`languageFallback` 或 `latest: false` 不触发枚举。

### 项目注释字段

`commentFields` 按字段值筛选声明，`commentFieldFacets` 按需列出候选值及各自命中数。两者都只读当前快照已发布的字段；字段定义来自各模块 `cjdoc.toml` 的 `[comments]`（见[配置参考](configuration.md#comments项目注释规范)），`filters` 里的 `owner` 仍指声明所有者。

```bash
cjdoc query --snapshot target/doc/docs.json --request request.json
```

```json
{"operation":"search","commentFields":[{"id":"owner","value":"platform"}]}
```

- `commentFields` 是 1–64 条 `{id, value}`；`id` 符合 `[a-z][a-z0-9-]{0,63}`，`value` 长 1–16384。匹配是完整字符串、大小写敏感、不做归一化，所以 `Platform` 不命中 `platform`。
- 同一条件里的多项取 AND，并与已有 `filters`、`tags`、重载选择器一起取 AND；命中声明的 `match.reason` 为 `filter_only`、分值为 0。
- 只有正文提到该值、没有写字段标签的声明不会命中；私有声明在 `external` 受众下不参与。
- 范围里没有该字段定义时返回 `not_found`；同名字段在多个模块或多个快照都存在时返回 `scope_mismatch`，需先用下面的目录请求取得限定身份。

候选值与计数默认不计算，显式请求才返回：

```json
{"operation":"search","commentFieldFacets":{"id":"owner","limit":20}}
```

响应在 `result.facets.commentFields` 给出 `{items, next}`，每行是各自独立的 `(snapshotId, moduleId, id, title, value, count)`：

```json
{"status":"ok",
 "result":{"items":[],
   "facets":{"tags":[],"commentFields":{"items":[
     {"scope":{"snapshotId":"cjdoc:snapshot:v1:…","moduleId":"cjdoc:module:v1:root"},
      "id":"owner","title":"负责人","value":"platform","count":1}],
    "next":null}}}}
```

- 省略 `commentFieldFacets` 时不做计数，响应里**没有** `facets.commentFields` 这个成员（不是空数组、也不是 `null`）；`{}` 表示只请求目录。
- `id` 限定字段名，`limit` 为 1–100、默认 20，`cursor` 至多 1024 字符。只有目录请求时 `result.items` 为空，不构成“全库没有命中”的结论。
- `count` 统计当前所有条件都成立的全部声明，在命中分页的 `limit`/`offset` 之前计算；`limit: 0`、翻页、重复值或重导出都不改变计数，同一声明不重复计数。
- 分页按 `(snapshotId, moduleId, id, value)` 的 UTF-8 字节序稳定推进；`next` 为 `null` 表示目录已到末尾。把 `next` 原样放回 `commentFieldFacets.cursor` 取下一页。
- 目录游标绑定投影与目录条件（`id`、`limit`）；改值、换语言/快照、改 `id` 或 `limit` 后旧游标返回 `stale_cursor`。命中页的 `cursor` 与目录的 `next` 是两个独立游标，不能互换。

### `get_symbol` 的章节与预算

`preset` 与 `sections` 互斥。`sections` 是 1–11 个不同章节，可取 `signature`、`parameters`、`returns`、`contracts`、`examples`、`description`、`relations`、`source`、`diagnostics`、`validation`、`diff`。

| `preset` | 内容 |
|---|---|
| `summary` | `signature`、`description` |
| `call` | `signature`、`parameters`、`returns`、`contracts` 必给，`examples` 在预算允许时加入 |
| `reference` | 全部章节 |

不给 `preset` 也不给 `sections` 时使用全部声明章节。概念页的 `pageId` 只能用 `summary` 或 `reference`，可请求章节限于 `description`、`source`、`validation`、`diff`。每个章节的状态取 `available`、`missing`、`not_selected`、`budget_omitted`、`unavailable`。

`maxBytes` 范围 1 KiB–64 MiB，默认 65,536 字节，覆盖章节正文与结构化值。必要内容放不下时返回 `budget_exceeded`，带真实 `requiredBytes` 与可执行的 retry：

```json
{"status":"budget_exceeded",
 "error":{"code":"required_unit_exceeds_budget",
          "message":"The intact mandatory documentation units do not fit the content byte limit.",
          "requiredBytes":3545,"maximumBytes":1024},
 "completeness":{"content":{"retry":{"maxBytes":3545,
   "detail":"Retry the same sections with maxBytes at least 3545."}}}}
```

可选章节按完整章节省略；硬资源限制无法满足时是 `resource_limit`，不能靠重复请求索取不存在的完整内容。核心 result JSON 的 64 MiB 限制独立于 `maxBytes`。

`relations` 展开：`direction` 取 `outgoing`、`incoming`、`both`（默认 `both`），`kinds` 最多 32 个，`depth` 默认 `1`、范围 `0..4`，`limit` 默认 `25`、范围 `0..100`。只遍历快照中已捕获的关系，并按 `(snapshotId, symbolId)` 去环。深度截断给出提高 depth 的提示（最多 4），数量或字节截断给出关系遍历 cursor。额外快照只能通过最多 64 个 `relatedSnapshotIds` 显式选择；跨 root 或依赖不能凭裸本地 Symbol ID 合并。

## 搜索匹配

`precise` 依次比较：精确 `symbolId`/`symbolKey`、限定名、声明名、owner-member、重导出别名，再到标识符或文档 token。参数/返回类型不扩大精确自由文本范围，但可用结构化条件筛选。最高证据等级有多个候选时返回 `ambiguous`，不按哈希顺序挑重载。

`discovery` 按分数排序并可返回多个候选：

| 分值 | 证据 |
|---:|---|
| 12000 | 精确 `symbolId` 或 `symbolKey` |
| 11000 | 精确 qualified name |
| 10000 | 精确声明名、owner-member 或可见别名 |
| 9000 / 8000 / 7000 | ASCII 折叠名称 / 名称前缀 / qualified-name 前缀 |
| 6000 / 5000 | 所有 query token 的词前缀 / acronym |
| 4000 / 3000 | 结构化声明文本 / 单 token 一次编辑距离 |
| 2000 | 文档正文或概念正文 |
| 0 | 仅由 scope、filters、tags 枚举（`filter_only`） |

`full-ir` 索引捕获的完整正文；`bounded-static` 每条记录只索引正文前 2,000 个 Unicode 码点，身份、参数、返回与分类字段不截断。摘要预览最多 240 码点，签名预览最多 512 码点，截断时省略号计入限长。HTML 静态搜索索引只提供 `bounded-static` 且只支持 `search`；对静态索引请求 `full-ir` 返回 `unavailable`（`search_profile_unavailable`）。

检索只做 ASCII 大小写折叠，不做 NFC/NFKC 或非 ASCII 大小写折叠。token 由 ASCII 字母、数字、下划线和 U+0080 以上码点组成，其余字符分隔 token；camelCase/acronym 分界只识别 ASCII 大小写边界。一次编辑距离只对 4–128 码点的单 token 开放，允许一次插入、删除或替换，不含换位。

结果按 `(snapshotId, canonical symbol/page ID)` 去重；不同 snapshot、module、owner、origin 不合并。排序先按分值降序，再按 snapshot ID、canonical ID、reason 的 UTF-8 字节序稳定排列。`result.facets.tags` 按当前全部过滤条件统计可见 canonical 声明，按 ID 而不是标题展示。

## 结果 `cjdoc.query-result/5`

| 字段 | 内容 |
|---|---|
| `schemaVersion` | 恒为 `cjdoc.query-result/5` |
| `status`、`operation` | 查询域状态与操作名 |
| `scope.requested` | 原始请求 |
| `scope.catalogId` | 加载内容身份 |
| `scope.snapshots` | 每个选中快照的 `snapshotId`、`sourceSnapshotId`、`sourceKind`、`language`、`audience`、`apiCollectionState`、`publicationRevision`、`packagedRepresentations` |
| `selection` | `resolve_docs` 的 `strategy`（`captured-dependency-policy` 或 `explicit-latest-alias`）、`selected`、`candidates`；其他操作为 null |
| `result.items` | 命中条目，最多 101 条 |
| `result.relations` | 关系条目，最多 100 条 |
| `result.reports` | 附加的 validation/diff 报告，最多 64 条 |
| `result.facets.tags` | 标签统计；非 `search` 时为空 |
| `completeness` | `apiCollection`、`query`、`content` |
| `sources` | 被选输入的源码路径、可用 URL 与捕获状态，最多 64 条 |
| `text` | 与 envelope 对应的人类可读说明，不替代结构化字段 |
| `error` | 正常域结果为 null；执行失败时为 `code`、`message`、`requiredBytes`、`maximumBytes` |

`items[].identity` 给出 snapshot/source snapshot、document set、module、dependency instance、symbol/page 身份；优先原样保留 ID/key，不要从被截断的摘要猜身份。

`completeness.query.complete` 为 `true` 时 `next` 必为 null；存在 `next` 时 `complete` 为 `false`。`total = null` 表示未知。`completeness.content.retry` 只在 `budget_exceeded` 时非 null。

只用 Doc IR 作为输入时 `packagedRepresentations = false`，规范路由不代表资源真的随包复制，但完整正文仍可由 `get_symbol` 读取；装载 `agent/manifest.json` 才会校验资源哈希与完整表示映射。`result.reports` 中 validation/diff 是报告原文与绑定信息，`not_attached` 不是通过，附着本身也不证明报告生产者可信。

## 状态与退出码

| `status` | 退出码 | 含义 |
|---|---:|---|
| `ok` | 0 | 请求的查询成功 |
| `ambiguous` | 0 | 候选不能唯一决定；正常结果，调用方需按身份缩小范围 |
| `not_found` | 0 | 在已加载且可见的完整范围内没有匹配 |
| `source_incomplete` | 0 | 输入 API collection 本身不完整，不能据此推断全库不存在 |
| `invalid_request` | 2 | JSON、schema、字段适用性或字段值错误 |
| `scope_mismatch` | 2 | 指定快照、language/audience/cfg 或身份不在加载集合中 |
| `stale_cursor` | 2 | cursor 格式错误、绑定不匹配或偏移越界 |
| `budget_exceeded` | 3 | 必要内容超过 `maxBytes`，可按 `requiredBytes` 重试 |
| `resource_limit` | 3 | 硬资源或输出上限不允许完成请求 |
| `unavailable` | 3 | 所需证据、输入或可选能力不可用 |

### `error.code`

`error.code` 比 `status` 更细，常见值：

| `status` | `error.code` |
|---|---|
| `invalid_request` | `request_json`、`request_byte_limit`、`request_schema`、`unknown_field`、`field_not_applicable`、`request_value`、`snapshot_count`、`request_required`、`request_option`、`read_command_option`、`read_command_input`、`relation_direction` |
| `scope_mismatch` | `snapshot_unavailable`、`projection_unavailable`、`context_not_captured`、`related_snapshot_not_loaded` |
| `stale_cursor` | `cursor_format`、`cursor_binding`、`cursor_range` |
| `budget_exceeded` | `required_unit_exceeds_budget` |
| `resource_limit` | `source_total_byte_limit`、`catalog_model_byte_limit`、`bundle_resource_limit`、`bundle_resource_count`、`version_source_limit`、`result_wire_byte_limit`、`render_resource_limit`、`dependency_evidence_work_limit` |
| `unavailable` | `snapshot_io`、`doc_ir_hash_mismatch`、`inventory_hash_mismatch`、`resource_hash_mismatch`、`manifest_missing`、`unsafe_resource_path` 等快照或表示证据问题 |

## 游标与继续读取

cursor 是 `cjdoc.cursor/2` 的不透明 token，不要手工构造、解析或当作凭据。它绑定冻结输入内容/catalog、projection、profile，以及除 `cursor` 外的规范化完整请求（scope、query、mode、filters、tags、排序、语言、fallback、受众、limit 与预算）。filters/tags 的顺序与重复项会先规范化。

续页时只把响应里 `completeness.query.next` 或关系返回的 cursor 原样放回同一请求，其余字段保持不变。改变输入、范围、查询条件、模式、profile、limit、语言或预算，必须去掉 cursor 从第一页重查；旧 token 返回 `stale_cursor`，不会把不同查询的观察混在一起。`get_symbol` 必要内容超过预算时，用新预算并去掉旧 cursor 重查。

关系遍历的 cursor 只继续同一个已冻结的关系遍历；`relations.depth` 截断给出提高深度的 omission/retry，而不是声称已枚举完图。超过最大深度 4 或硬限制时没有更深的入口。

## 本地 stdio MCP

MCP 是可选的读取适配，不是生成、静态站或 `query` 的前提。启动时传入同一组固定快照：

```bash
cjdoc mcp --snapshot target/doc/html/agent/manifest.json
```

传输遵循 MCP 2025-11-25 stdio：一行一个 UTF-8 JSON-RPC 2.0 object，stdout 只用于协议消息。一个 server 对应一份加载完成的冻结查询会话。

### 生命周期

1. 客户端发送一次 `initialize` 请求，需含 `protocolVersion`、object `capabilities`、`clientInfo.name`、`clientInfo.version`。
2. 服务端返回协议版本 `2025-11-25`、tools capability、server info 与说明；客户端随后必须发送 `notifications/initialized`。
3. 收到初始化通知后进入 ready，可调用 `tools/list`、`tools/call`。ready 之前调用这两项、或重复 `initialize`，都返回 JSON-RPC `-32600`。
4. 工具固定为 `resolve_docs`、`search`、`get_symbol`；`tools/list` 不分页、不接受 cursor，`listChanged` 为 `false`。tool arguments 直接是对应操作的字段，不能传 `operation`——工具名决定操作。
5. stdin EOF 是正常关闭，没有 shutdown RPC。空行忽略，CRLF 接受，单个 JSON-RPC batch 不支持。

### 工具结果

`tools/call` 结果的 `structuredContent` 是完整 `cjdoc.query-result/5` envelope，`content[0].text` 是同一 envelope 的 `text` 字段。`isError` 只对 `ok`、`ambiguous`、`not_found`、`source_incomplete` 为 `false`；其他查询状态是 tool execution error，但仍以正常工具结果结构返回，而不是 JSON-RPC 协议错误，因此调用方仍能读到完整状态与 `error` envelope。

### 错误分层与限制

JSON-RPC 协议层错误码：`-32700` parse error、`-32600` invalid request（含尚未 ready）、`-32601` method not found、`-32602` invalid params、`-32603` internal error。未知工具、`params` 非 object、重复传 `operation`、无效初始化参数属于协议/工具调用层错误；请求字段、查询 scope、预算问题由 query core 的 `cjdoc.query-result/5` 状态报告，两者不混用。

MCP 每条输入最多 1 MiB、JSON 深度 64；工具 schema 最多 8 MiB；响应外层最多 130 MiB（含 `structuredContent`、`content[0].text` 与 JSON-RPC 封装）。正常 `query` 只返回核心 envelope，三者上限互相独立。

客户端还需要正确的 cjdoc 动态运行时库搜索路径；进程不能继承环境时，要在该客户端的 MCP server 配置里显式设置平台运行时路径。客户端自身的调度前提（例如 Codex CLI 0.163 需要的 `codex-code-mode-host`）不属于 cjdoc，也不表示模型已调用 cjdoc。
