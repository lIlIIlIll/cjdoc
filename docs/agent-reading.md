# 逐声明读取、查询与 MCP

cjdoc 的机器读取与静态站搜索都使用捕获的声明投影。CLI、公开查询核心和本地 MCP 支持 `precise`/`discovery` 两种模式及 `full-ir`/`bounded-static` 两种检索文本范围；HTML 静态搜索使用 discovery + bounded-static。renderer 只读取 Doc IR 和已发布索引，不回抓 HTML 正文、不调用模型、不重新编译源码或重跑示例。

## 生成与部署

```bash
cjdoc generate --project examples/pocketkit/demo-v2 \
  --format html --format json --agent-full --locale en \
  --doc-version demo-v2 --output target/agent-demo
```

已有当前版本 Doc IR 时可以离线重放：

```bash
cjdoc render --input target/agent-demo/docs.json \
  --format html --agent-full --locale en --doc-version demo-v2 \
  --output target/agent-replay
```

HTML 输出默认附带每个可见声明的 Markdown/JSON，不需要 `--agent-full`。该选项只增加聚合全文。

单独选择 `--format markdown` 保留既有包页、容器页及其中的成员正文布局；`--format json` 保留完整 Doc IR 输出。需要每声明独立 Markdown/JSON 时，部署完整 HTML 文档根并保留其中的 `agent/`；不要只搬运 `agent/`，否则 manifest 指向的 HTML 和全文入口会丢失。仅选 Markdown 或 JSON 格式不生成 HTML、机器包 manifest 或不存在的 HTML alternate。

| 文档根中的入口 | 用途 |
|---|---|
| `llms.txt` | 精简发现入口，链接导航、表示 manifest 和已启用的全文索引；不是全站正文。 |
| `navigation-index.json` | `cjdoc.navigation-index/2` 第一片；读取 `pagination.next` 直至结束。 |
| `agent/manifest.json` | `cjdoc.machine-manifest/1`；区分 symbol、concept、package、project 映射。 |
| `agent/docs.json`、`symbol-index.json` | 与 manifest 快照一致的自包含 Doc IR/唯一库存；Doc IR 当前为 `cjdoc.doc-ir/17`。 |
| `agent/symbols/` 中的 JSON | `cjdoc.declaration/2`；每条声明带有同形 `classification` 元数据。 |
| `search-index.json`、`search-index.js` | `cjdoc.search-index/11` 与内嵌 `cjdoc.search-contract/2`；HTML 搜索执行 discovery/bounded-static。 |
| manifest 的 `representations` | 每条记录给出实际 HTML、Markdown、JSON 相对路径；不要拼接 slug 或替换扩展名。 |
| `agent-full-index.json` | 仅 `--agent-full`：全文各片的顺序、SHA-256、单元数及完整性。 |

路径基准是**当前文档根**，不是服务器根或其他格式的兄弟目录。部署整个 `html/`，不要只复制 HTML 文件。HTML head 的 `alternate` 指向随站点发布的逐页/逐声明 Markdown，`describedby` 指向同一根的 `llms.txt` 和 manifest。内容协商不是前提；普通静态托管、项目子路径和 `file://` 均使用这些文件。

上述路径基准适用于 manifest 与索引记录。逐页/逐声明 Markdown 及 JSON 中的 Markdown 正文，按实际表示文件的位置生成相对链接；聚合全文与 `get_symbol` 正文以文档根为基准。本地声明和捕获的外部语义链接均指向规范 HTML，不跳到假定的 `../html/` 兄弟目录。

读取全文时，先检查 `agent-full-index.json.snapshotId` 等于机器 manifest 的 `snapshotId`，再确认 manifest 的 `publicationRevision` 是所选发布修订，并检查各片的 hash、范围及续取。全文索引不重复提供发布修订；API 包版本与文档发布修订读取结构化作用域，不解析正文中的展示标签。

Showcase 页面的可见 Markdown 操作也读取该 manifest，以实际 HTML 路径选中对应表示；不从声明标题、签名或旧聚合 Markdown 推算文件名。概念页沿用相同映射。没有已发布表示的报告页不提供指向无关聚合内容的 Markdown 操作。

`sidebar-index.js` 只共享重复的侧栏导航元数据；完整声明页、包/成员索引和源码签名仍保留。它与其他资源一起静态部署，不通过 fetch 或额外服务装载。

`--all-languages` 为各语言生成独立文档根。多版本组合沿用 [高级用法](advanced-usage.md#组合多版本文档站)：组合完整版本目录，保留各语言根、manifest 和分片。`--doc-version` 是**文档发布标签**，不是依赖包版本或编译器认证。

## CLI：读取固定输入

使用已安装或已明确构建的原生 `cjdoc` 可执行文件。进程仍需要匹配的仓颉运行时库；读取不要求编译器、项目源码、原外部 inventory 或网络。源码仓库的 `./cjdoc` 开发包装器在缺少构建产物时会构建 cjdoc 本身，不是无编译器部署入口。

`--snapshot` 可重复，接受当前 Doc IR、文档根/`agent/manifest.json`，或已有 `versions.json`：

```bash
python3 - <<'PY'
import json
from pathlib import Path
Path('request.json').write_text(json.dumps({
    'schemaVersion': 'cjdoc.query-request/3',
    'operation': 'search',
    'query': 'pocketkit.TextCatalog.add',
    'apiVersion': '0.2.0',
    'limit': 1,
}), encoding='utf-8')
PY
cjdoc query --snapshot target/agent-demo/html/agent/manifest.json \
  --request request.json > result.json
```

`--request -` 从 stdin 读取一个 JSON 对象。stdout 只包含一个 `cjdoc.query-result/3` 对象；诊断不混入 stdout。输入源在会话创建时严格装载，随后继续读取同一捕获内容，不按 PATH 里的 SDK 或当前工作区重新选版本。

### 三个操作

| 操作 | 核心输入 | 返回范围 |
|---|---|---|
| `resolve_docs` | library、模块/包范围、捕获的 dependency/context、API 版本和显式策略；`query` 只匹配库/模块/包名，符号名使用 `search` | 选中项、可区分候选、matchLevel、原因与原始依赖证据。 |
| `search` | Symbol ID/key、限定名、名称/别名、参数类型/泛型数量、结构化字段筛选或用途文字 | 精确身份/重载特征优先，随后名称及正文；摘要、完整源码签名、详情身份、分类和规范路由。 |
| `get_symbol` | `symbolId`、`symbolKey`、`pageId` 恰好一个；固定快照/文档集 | 所选完整章节、关系、来源、分类与附带报告；概念页没有伪造的 Symbol ID。 |

完整字段、操作适用性和取值以 `cjdoc schema query-request` 为准；请求为 `cjdoc.query-request/3`，结果为 `cjdoc.query-result/3`。未知字段、身份选择冲突、`sections` 与 `preset` 同时出现、不适用的操作选项都会被拒绝。`mode`、`profile`、`filters` 和 `tags` 只适用于 search，其他操作收到这些字段会返回 `invalid_request/field_not_applicable`。未填写 `mode`/`profile` 时原生查询默认 `precise`/`full-ir`。显式提供旧 query-request/query-result 版本会被拒绝。

### Search 与固定查询

#### 模式、profile 与排名

`precise` 是原生查询的默认模式。它优先使用精确 `symbolId`/`symbolKey`、qualified name、名称、owner-member、重导出短别名，再匹配声明标识符或文档文本的 token；参数和返回类型不会额外扩大 precise 的自由文本范围，但仍可用显式字段条件筛选。最高证据等级并列时返回 `ambiguous`，不会按遍历顺序猜一个重载。`discovery` 用于浏览和渐进发现：多个正常候选可同时返回，按共享契约的分数从高到低排序。

| discovery 分数 | 证据 |
|---:|---|
| 12000 | 精确 `symbolId` 或 `symbolKey` |
| 11000 | 精确 qualified name |
| 10000 | 精确声明名、owner-member 或可见 alias |
| 9000 / 8000 / 7000 | ASCII 折叠名称 / 名称前缀 / qualified-name 前缀 |
| 6000 / 5000 | 所有 token 的词前缀 / acronym |
| 4000 / 3000 | 结构化声明文本 / 一次编辑距离 |
| 2000 | 文档正文或 concept 正文 |
| 0 | 仅使用 scope/filters/tags 枚举（`filter_only`） |

`full-ir` 检索捕获的完整正文；`bounded-static` 每条记录只索引正文前 2,000 个 Unicode 码点，结构化身份、参数、返回值及分类不截断。摘要展示可能截短为 240 个码点，但匹配使用完整摘要。原生查询支持两个 profile；原生与浏览器执行器都支持 `precise` / `discovery` 两种模式。发布的静态索引只提供 `bounded-static`，页面输入适配显式使用 `discovery` + `bounded-static`。
静态站只提供 `search` 操作：其他 operation 返回 `invalid_request/operation_unavailable`，请求 `full-ir` 返回 `unavailable/search_profile_unavailable`，不会伪装成空结果。

搜索结果使用 canonical 声明去重，key 为 `(snapshotId, symbolId)`，concept 使用 `(snapshotId, pageId)`；不同 snapshot、module、owner 或 origin 不合并。排序按 score 降序，再按 snapshot ID、canonical ID、reason 的 UTF-8 字节升序，结果顺序不依赖哈希表或语言环境。`total` 是当前 scope 和全部过滤条件下的去重候选数，不是当前页条数；`limit: 0` 返回空页但保留真实总数，且不发出无进展游标。精确最高分并列仍保留 `ambiguous` 语义。
标签或分类标题不会改变标签成员关系。一个 group ID 在多个 module/package/declared-owner scope 中出现时，每个 scope 独立选择标题和分组；分类标题与 group order 只影响展示，不参与 SymbolId 或 API fingerprint。

每个 search 结果还可包含 `coverage`：profile、projectionId、bodyTextLimit、bodyComplete 和 truncatedEntries。`bounded-static` 的 `bodyTextLimit` 为 2000；`full-ir` 为 null。已建立投影的零命中也带真实 coverage；非 search 结果或建投影前失败时为 null。若源采集本身不完整，仍会报告 `source_incomplete`，不能把索引覆盖不完整当作完整未命中。

#### 字段过滤与精确标签

`filters` 是最多 64 个 `{field, op, value}` 条件，所有条件 AND：field 是 `name`、`qualifiedName`、`owner`、`param`、`return`、`package` 或 `kind`；op 是 `eq` 或 `contains`；value 是 1–16384 个字符的非空字符串。`eq` 大小写敏感；`contains` 只折叠 ASCII `A`–`Z`，不做 Unicode normalization 或 locale 折叠。`name`、`qualifiedName`、`symbolId`、`symbolKey` 作为顶层字段时保留其既有精确选择语义，`filters` 是额外收窄条件。多个名称/限定名/包条件必须同时在同一个 canonical/exposure 上下文成立；参数按单个参数值匹配，不会把两个参数拼起来。

`tags` 是 1–64 个 ID 的数组，接受 1–64 个 ASCII 字母、数字、`-`、`_`，大小写敏感、精确相等；重复项会去重并按 UTF-8 字节排序，多个 ID 是 AND 交集；空数组会被拒绝，不筛标签时省略该字段。定义标题、正文提及或 ID 前缀都不等同于标签成员关系。concept 页没有 tag 集合，因此带 tags 的搜索不会返回 concept。

例如，在具有这些分类的文档中，下面的请求只返回 package 为 `pocketkit` 且同时具有 `streaming`、`extension-point` 的可见声明：

```json
{
  "schemaVersion": "cjdoc.query-request/3",
  "operation": "search",
  "query": "",
  "profile": "full-ir",
  "mode": "discovery",
  "filters": [
    {"field": "package", "op": "eq", "value": "pocketkit"}
  ],
  "tags": ["streaming", "extension-point"],
  "limit": 20
}
```

没有文字 query、但提供有效 scope、filters、overload selector 或 tags 时，查询枚举通过条件的集合，score 为 0、reason 为 `filter_only`。完全没有 query 或有效过滤条件时返回空结果。仅提供 mode、profile、limit、cursor、languageFallback 或 `latest: false` 不会触发枚举；执行器补齐的默认 scope 也不算用户筛选。游标同时绑定这一语义区别，不能在续页时移除唯一的显式 scope。

#### 搜索文本规则

搜索仅 ASCII 大小写折叠；不做 NFC/NFKC、locale 或非 ASCII 大小写折叠。token 由 ASCII 字母、数字、下划线及所有 U+0080 以上码点组成，其他码点分隔 token。discovery 的 camelCase 与 acronym 拆分只识别 ASCII 大小写边界。一次编辑距离只允许对 4–128 码点的单 token 执行一次插入、删除或替换，不包含转置。HTML 输入保留 `name:`、`owner:`、`param:`、`return:`、`package:`、`kind:` 六种字段；package/kind 下拉选项是精确过滤。重复 `tag:<id>` 使用相同 ID 集合规则；未知字段或空值会显示结构化错误，不会被忽略。其余文本作为自由 query。

HTML 的搜索链接将每个 `tag`、`moduleId` 和 `snapshotId` 写入当前 locale 的站点 index URL。链接保留标签来源，不把不同 module 或 dependency 的同名标签合并；HTTP 子路径和 `file://` 页面都能由这些 query 参数恢复搜索状态。

`result.facets.tags` 是当前搜索条件（包括所有 tags）筛选后的可见 canonical 声明计数，按 snapshot/module/tag 分域，不计算 exposure 或隐藏声明。facet 项为 `{scope, id, title, count}`；scope 保留 `snapshotId`、`sourceSnapshotId`、`moduleId`、`documentSet`、`dependencyInstance` 及 `dependencyInstanceState`。非 search 结果的 `facets.tags` 为空数组。结果 item 的 `classification` 形状为 `{group: null | {id, packageName, ownerId, title, order}, tags: [{id, title}]}`；未分组时 group 为 null，ownerId/order 可以是 null；`get_symbol` 也返回 classification，concept 固定为 `{group: null, tags: []}`。tag title 可本地化显示，但过滤始终使用 ID。

#### 游标绑定与翻页

查询游标使用 `cjdoc.cursor/2` 格式，是会话局部 opaque token，不手工构造。它绑定捕获内容/projection、profile 和除 `cursor` 外的规范化完整请求（包括 scope、mode、filters、tags、排序相关条件和 limit）；条件顺序、重复 tags/filters 会规范化。续取时只把响应里的 cursor 加回原请求。改变输入、模式、profile 或任何查询字段后，必须从第一页重查。

`resolve_docs` 复用依赖文档选择规则。`contextSnapshotId`、`contextModuleId`、`dependencyInstanceId` 指向**已捕获**上下文；不会重新解依赖或观察 SDK。`compatible` 和 `languageFallback` 是显式策略。`latest` 只有输入版本 catalog 已声明对应别名时才有意义，解析后回显固定快照；它不能替代明确请求的 API 版本。

### 续取与精确读取

用原请求加服务返回的 opaque cursor，其他条件保持不变：

```bash
python3 - <<'PY'
import json
from pathlib import Path
request = json.loads(Path('request.json').read_text(encoding='utf-8'))
result = json.loads(Path('result.json').read_text(encoding='utf-8'))
request['cursor'] = result['completeness']['query']['next']
if request['cursor'] is None:
    raise SystemExit('query is already complete; no continuation is needed')
Path('next-request.json').write_text(json.dumps(request), encoding='utf-8')
PY
cjdoc query --snapshot target/agent-demo/html/agent/manifest.json \
  --request next-request.json > next-result.json
```

取某个候选的身份，不复制截断摘要或猜测 ID：

```bash
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path('result.json').read_text(encoding='utf-8'))
identity = result['result']['items'][0]['identity']
request = {'operation': 'get_symbol', 'snapshotId': identity['snapshotId'],
           'symbolId': identity['symbolId'], 'preset': 'call', 'maxBytes': 65536}
Path('detail-request.json').write_text(json.dumps(request), encoding='utf-8')
PY
cjdoc query --snapshot target/agent-demo/html/agent/manifest.json \
  --request detail-request.json > detail-result.json
```

cursor 绑定内容、查询条件、排序、语言/回退、受众和字节预算；换输入或改条件不能继续用旧 cursor。若初次或后续页的完整候选超出预算，按 `requiredBytes` 提高预算并移除旧 cursor，从原查询重新开始，再用新预算继续分页；不能同时修改预算又沿用旧 cursor。

`resolve_docs` 的目标 `snapshotId` 与消费者 `contextSnapshotId` 可以不同。显式消费者只提供已捕获的依赖上下文，不扩大目标候选的快照范围。

仅装载 Doc IR 时，`scope.snapshots[].packagedRepresentations` 为 false：结果中的规范路由不是文件已随输入打包的证明，完整正文仍可通过 `get_symbol` 取得。装载机器 manifest 才校验已打包资源的 hash、快照、库存及完整表示映射。外部源码 URL 是捕获的出处，不要求随离线包复制源码。

## 章节、状态和预算

声明预设：`summary` 取签名与说明；`call` 保留完整签名、参数、返回及必要契约，并按预算加入完整示例；`reference` 选择全部已支持章节。显式 `sections` 可选 signature、parameters、returns、contracts、examples、description、relations、source、diagnostics、validation、diff。概念页只支持 description、source、validation、diff，不适用调用预设。

参数、返回、泛型、源码 token、Markdown AST、完整 DocTag 与导航直接保留已有记录。没有结构化命名参数字段时保留源码签名/`sourceApiSignature`，不自行解析头部补造布尔值。九类行为契约以及 throws、deprecated、since 与完整示例不被折成一行。

`Unit` 的冗余返回类型行可以省略，但作者的 `@return` / `@returns` 正文（包括多条说明）不省略。返回类型未知时也保留已有返回说明，不补造类型。

| 维度 | 读取位置及含义 |
|---|---|
| API 收集 | `completeness.apiCollection`：resolved/partial/unavailable，与当前 top-k 无关。 |
| 查询枚举 | `completeness.query`：实际范围、offset、returned、total、complete、next。未知总数为 null；关系续取的 scope 为 relations，returned 数关系而不是重复的主体声明。 |
| 内容 | `completeness.content`：selectedSections、missingSections、omittedSections、retry；区分来源缺失、未选择与预算省略。 |
| 匹配/语义/导航 | 保留各自状态；manual、verified dependency、resolved navigation 都不代表类型检查或消费者行为通过。 |
| 正文语言 | reading language 是阅读偏好；DocTag 的 contentLanguage/translationState 和页面 language 说明实际作者正文及回退。回退不切换 API 版本。 |

| 限制 | 当前值 |
|---|---|
| 显式快照输入 | 1–64 个；规范 Doc IR 合计最多 64 MiB，读入文件累计最多 512 MiB。 |
| 请求 | 一个 UTF-8 JSON 对象，最多 1 MiB，嵌套深度 64。 |
| 结果数量 | 搜索默认 20，最大 100；0 表示主动不读取，不是不存在声明。 |
| 内容字节预算 | 默认 64 KiB，可请求 1 KiB–64 MiB；按完整章节的正文和结构化值计算，不是 token 保证。 |
| 核心结果 wire | 序列化 JSON 最多 64 MiB，和内容预算独立；超限返回 resource_limit，不截断 JSON。 |
| 关系 | 默认深度 1、数量 25；深度最多 4、数量最多 100，可筛 direction/kinds。仅沿捕获关系走，按快照内准确身份防环。 |
| 静态分片 | navigation/full 每片 16 MiB；摘要 16 KiB；单产物 64 MiB、总产物 512 MiB、条目 65536。 |

必要调用单元放不下时返回 `budget_exceeded`、真实 requiredBytes 和可行重试；超出硬资源范围时是 `resource_limit`，不提供不存在的完整读取入口。可选章节只整章省略。关系第一条记录都放不下时不给原地循环的 cursor。额外上下文只进入 `relatedSnapshotIds` 显式选择的快照；跨 root/dependency 不用裸本地 Symbol ID 认定同一目标。

跨快照导航还必须匹配捕获文档集的库、API 版本、语言、受众及 target/cfg，并绑定消费者所选组件的完整传递依赖上下文。仅有相同 API identity 和 portable key 不足以绑定另一个上下文。图证据可以保留在未发布 `ModuleDoc` 或声明的依赖组件中；这不会合成该组件的文档。证据不足或不匹配时保留 `unavailable`，多个匹配保留 `ambiguous`；原始导航及匹配等级继续保留，不将 manual/compatible 升级为 exact。

| status | CLI 退出码 | 解释 |
|---|---|---|
| ok、ambiguous、not_found、source_incomplete | 0 | 正常领域结果；后两者只说明已声明的捕获范围。 |
| invalid_request、scope_mismatch、stale_cursor | 2 | 请求或固定范围不成立。 |
| budget_exceeded、resource_limit、unavailable | 3 | 预算、硬限制或输入可用性问题。 |

## 本地 stdio MCP

MCP 是可选消费适配，不是生成或静态阅读的前提。使用同一组固定输入：

```bash
cjdoc mcp --snapshot target/agent-demo/html/agent/manifest.json
```

stdio 遵循 [MCP 2025-11-25 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)：initialize → notifications/initialized → 工具请求；关闭 stdin 后退出。仅声明 resolve_docs、search、get_symbol。参数就是对应操作字段，不再重复传 operation。`content[0].text` 是核心正文，structuredContent 是完整核心结果；领域失败与 JSON-RPC 协议错误分开。

Codex CLI 的 TOML 配置示例（从能解析这些输入路径的目录启动）：

```toml
[features]
code_mode_host = true

[mcp_servers.cjdoc]
command = "cjdoc"
args = ["mcp", "--snapshot", "target/agent-demo/html/agent/manifest.json"]
required = true
startup_timeout_sec = 120
tool_timeout_sec = 180
# Linux 且运行库不在系统搜索路径时，替换为实际运行库搜索路径：
env = { LD_LIBRARY_PATH = "<Cangjie-runtime-library-path>" }
```

Codex 0.163 需要配套的 `codex-code-mode-host` 才能发现和调度 MCP 工具，即使 `code_mode` 未启用也不能禁用该 host。它是客户端调度前提，不等于启用 shell 或网页工具。Codex 不保证把启动终端的运行库环境传给 MCP 子进程：Linux 显式配置适用的 `LD_LIBRARY_PATH`，macOS 使用对应的 DYLD 搜索路径，Windows 则配置包含运行库 DLL 的 `PATH`；运行库已经安装到系统搜索路径时可省略环境项。

`required = true` 要求客户端等真实连接完成初始化，不能在较大的多 snapshot 输入尚未加载时就把文档工具当作不存在。启动与工具超时仍受客户端整体任务期限约束。

MCP 消息使用一行一个 UTF-8 JSON 对象；请求仍是 1 MiB。传输会再次携带可读正文，因此外层最多 130 MiB，不能把核心内容预算冒充整个协议包预算。`serve` 保持项目预览/重建用途；不要把它当作只读 MCP。

## 已有验证与 diff 报告

只发布已经存在的 JSON 报告，不执行新的检查：

```bash
cjdoc render --input target/agent-demo/docs.json --format html \
  --validation-report validation.json --api-diff-report api-diff.json \
  --output target/agent-with-reports
```

两个选项也适用于 generate，但要求 HTML 目录输出，不能与 stdout 组合。原始报告随 `agent/reports/` 发布，SHA-256 与 manifest 关联。查询 validation/diff 章节按需返回原始报告和绑定状态；报告中的未检查、编译、运行、失败或跳过信息保持原意。

`not_attached` 不是通过；只有报告关联不代表其生产者可信。缺少内容 hash、实际输入/工具链/配置记录时保留 binding_unavailable，快照或配置不符是 binding_mismatch。源码/诊断、示例代码存在或站点构建成功都不是执行回执。已有 api-diff/2 缺少双输入内容指纹时，保留 baseline/current 原文，不从文档标签回填认证。

## schema 与升级

```bash
cjdoc schema list
cjdoc schema navigation-index-v2
cjdoc schema agent-full-index
cjdoc schema declaration
cjdoc schema page
cjdoc schema machine-manifest
cjdoc schema query-request
cjdoc schema query-result
cjdoc schema doc-ir-v17
cjdoc schema search-index-v11
```

`schema navigation-index` 指向当前 v2；`schema navigation-index-v1` 和已发布的旧 navigation schema 仍保持冻结。v1 没有整体完整性/续取证据，不能据其语法合法认定全站枚举完整。当前 decoder/query 接受 Doc IR v17；Doc IR v16 和更早版本不迁移。当前机器协议为 query-request/3、query-result/3、search-index/11、declaration/2；显式旧协议版本不会被当作当前输入接受。需要使用旧快照时，应在真实源码上重新生成当前 Doc IR/站点，而不是把旧 JSON 改写版本字段。

当前 search static index 是 `cjdoc.search-index/11`，以共享 `cjdoc.search-contract/2` 执行器提供 bounded-static 语义；`cjdoc.declaration/2` 在每条声明中带 classification。静态索引的旧版本或不支持的 profile 会给出明确能力错误，不会静默显示零命中。

公开仓颉入口为 `cjdoc.DocumentationQuerySession`，可从显式路径、一个 `cjdoc.model.DocumentationSet` 或其数组创建；`execute(String)` 返回同一版本化 JSON，`catalogIdentity` 暴露捕获内容身份。静态投影由 `cjdoc.render.DocumentationReadSnapshot` 及现有 renderer 提供。运行可重现模型对照、消费者编译与行为验收见维护者的 [Agent 评测流程](maintainer/agent-evaluation.md)；普通静态使用不要求模型或网络。

完整发布、离线隔离、固定规模成本及三次真实客户端观测的正反结果见 [issue #137 验收记录](research/agent-reading-acceptance.md)。其中保留所有失败，不把正常退出、较少读取或一次模型观测当作整体改进。
